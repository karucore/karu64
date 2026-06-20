//	eth_backend.c
//	Host-side sim packet backend for flow/fpga/eth/eth_mii_dpi.v (Ethernet phase E2c).
//	The DPI bridge hands us each MII frame karu64/U-Boot transmits and clocks our
//	replies back in, so U-Boot's net stack has something to talk to: ARP, ICMP
//	echo (ping), and a TFTP read-server (tftpboot). Self-contained -- no host TAP
//	or root needed; deterministic for CI.
//
//	The DPI carries raw *wire* bytes (preamble 0x55.. + SFD 0xD5 + ethernet frame
//	+ FCS). We strip that on TX and rebuild it (with a fresh CRC-32 FCS) on RX.
//
//	Config (plusargs): +eth_server_ip=A.B.C.D (default 192.168.1.20)
//	                   +tftp_dir=<path>       (default ".")
//	                   +eth_verbose          (log each handled packet)

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <verilated.h>

//	---- config (resolved from plusargs in eth_backend_init) ----
static uint8_t  g_mac[6] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };	//	server MAC
static uint32_t g_ip     = (192u<<24)|(168u<<16)|(1u<<8)|20u;		//	server IP
static char     g_tftp_dir[512] = ".";
static int      g_verbose = 0;	//	+eth_verbose: one line per ARP/ICMP/TFTP
static int      g_trace   = 0;	//	+eth_trace:   full per-frame hexdump
static int      g_inited  = 0;
//	+eth_tap=<dev>: bridge to a host TAP (real host stack: dhcp/tftp/ping/ssh)
//	instead of the in-process responder. +eth_pcap=<file>: dump every frame.
static int      g_tap_fd  = -1;
static FILE    *g_pcap    = NULL;
static uint32_t g_pcap_ctr = 0;

//	================= host TAP + pcap =================
//	Attach to an existing (persistent, user-owned) TAP. No CAP_NET_ADMIN needed
//	for that; bringing the device up + assigning its IP is the host's job.
static int tap_open(const char *dev)
{
	int fd = open("/dev/net/tun", O_RDWR);
	if (fd < 0) { perror("[ETH-BACKEND] open /dev/net/tun"); return -1; }
	struct ifreq ifr;
	memset(&ifr, 0, sizeof ifr);
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI;	//	raw L2 frames, no 4-byte prefix
	strncpy(ifr.ifr_name, dev, IFNAMSIZ - 1);
	if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
		perror("[ETH-BACKEND] TUNSETIFF"); close(fd); return -1;
	}
	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl | O_NONBLOCK);	//	never stall the sim on a read
	printf("[ETH-BACKEND] TAP attached to %s (host stack is the peer)\n", ifr.ifr_name);
	fflush(stdout);
	return fd;
}

//	Minimal pcap (linktype 1 = Ethernet). Timestamps are a frame counter -- the
//	sim has no real time, and Wireshark only needs them monotonic.
static void pcap_open(const char *path)
{
	g_pcap = fopen(path, "wb");
	if (!g_pcap) { perror("[ETH-BACKEND] pcap fopen"); return; }
	uint32_t magic = 0xa1b2c3d4; uint16_t vmaj = 2, vmin = 4;
	int32_t  tz = 0; uint32_t sig = 0, snap = 65535, net = 1;
	fwrite(&magic,4,1,g_pcap); fwrite(&vmaj,2,1,g_pcap); fwrite(&vmin,2,1,g_pcap);
	fwrite(&tz,4,1,g_pcap); fwrite(&sig,4,1,g_pcap);
	fwrite(&snap,4,1,g_pcap); fwrite(&net,4,1,g_pcap);
}
static void pcap_write(const uint8_t *f, int n)
{
	if (!g_pcap) return;
	uint32_t ts_sec = g_pcap_ctr / 1000000, ts_usec = g_pcap_ctr % 1000000;
	uint32_t cap = n, len = n;
	g_pcap_ctr += 100;					//	~lexical spacing between frames
	fwrite(&ts_sec,4,1,g_pcap); fwrite(&ts_usec,4,1,g_pcap);
	fwrite(&cap,4,1,g_pcap); fwrite(&len,4,1,g_pcap);
	fwrite(f, n, 1, g_pcap); fflush(g_pcap);
}

//	================= outgoing wire-frame queue =================
#define MAXF   32
#define FMAX   1600
static uint8_t  q_buf[MAXF][FMAX];
static int      q_len[MAXF];
static int      q_head = 0, q_tail = 0;	//	ring: [head,tail)

//	enqueue one ETHERNET frame (no preamble/FCS); we add those on the wire.
static void queue_eth(const uint8_t *f, int len)
{
	int nxt = (q_tail + 1) % MAXF;
	if (nxt == q_head) return;			//	full -> drop
	if (len > FMAX) len = FMAX;
	//	Copy only the real bytes, THEN zero-fill the pad up to the 60-byte min
	//	Ethernet frame -- copying out_len from a shorter source (e.g. a 42-byte
	//	ARP reply) would read past it and leave the pad nondeterministic.
	int out_len = (len < 60) ? 60 : len;
	memcpy(q_buf[q_tail], f, len);
	if (out_len > len)
		memset(q_buf[q_tail] + len, 0, out_len - len);
	q_len[q_tail] = out_len;
	q_tail = nxt;
}

//	================= CRC-32 (Ethernet FCS) =================
static uint32_t crc32_eth(const uint8_t *p, int n)
{
	uint32_t c = 0xFFFFFFFFu;
	for (int i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1)));
	}
	return ~c;
}

//	16-bit one's-complement checksum (IP / ICMP / UDP).
static uint16_t cksum16(const uint8_t *p, int n, uint32_t init)
{
	uint32_t s = init;
	for (int i = 0; i + 1 < n; i += 2) s += (p[i] << 8) | p[i+1];
	if (n & 1) s += p[n-1] << 8;
	while (s >> 16) s = (s & 0xffff) + (s >> 16);
	return (uint16_t)~s;
}

//	big-endian field helpers
static uint16_t be16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|(p[1]<<16)|(p[2]<<8)|p[3]; }
static void wbe16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void wbe32(uint8_t *p, uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }

//	================= TFTP read-server state =================
//	One transfer at a time is plenty for U-Boot's lock-step tftp.
static FILE    *tftp_fp     = NULL;
static int      tftp_block  = 0;		//	last block we sent
static uint16_t tftp_cli_port = 0;		//	client's UDP port (TID)
static uint32_t tftp_cli_ip = 0;
static uint8_t  tftp_cli_mac[6];
static int      tftp_last_len = 0;		//	bytes in the last DATA payload
static int      tftp_blksize  = 512;		//	negotiated block size (RFC 2348)
static int      tftp_oack     = 0;		//	1 = OACK sent, awaiting block-0 ACK
#define TFTP_DATA 512
#define TFTP_MAXBLK 1468			//	cap: a DATA frame stays within a 1500 MTU

static void tftp_send_block(void);		//	fwd

//	================= packet handlers =================
static void handle_arp(const uint8_t *f, int len);
static void handle_ipv4(const uint8_t *f, int len);

extern "C" void eth_dpi_tx_byte(unsigned char b);
extern "C" void eth_dpi_tx_eof(void);
extern "C" int  eth_dpi_rx_byte(void);

static uint8_t  tx_buf[FMAX];
static int      tx_len = 0;

static void eth_backend_init(void)
{
	g_inited = 1;
	const char *p;
	if ((p = Verilated::commandArgsPlusMatch("eth_server_ip="))[0]) {
		const char *s = strchr(p, '=');
		if (s) {
			unsigned a,b,c,d;
			if (sscanf(s+1, "%u.%u.%u.%u", &a,&b,&c,&d) == 4)
				g_ip = (a<<24)|(b<<16)|(c<<8)|d;
		}
	}
	if ((p = Verilated::commandArgsPlusMatch("tftp_dir="))[0]) {
		const char *s = strchr(p, '=');
		if (s) { strncpy(g_tftp_dir, s+1, sizeof(g_tftp_dir)-1); }
	}
	if (Verilated::commandArgsPlusMatch("eth_verbose")[0]) g_verbose = 1;
	if (Verilated::commandArgsPlusMatch("eth_trace")[0])   g_trace = g_verbose = 1;
	if ((p = Verilated::commandArgsPlusMatch("eth_tap="))[0]) {
		const char *s = strchr(p, '=');
		if (s) g_tap_fd = tap_open(s + 1);
		if (g_tap_fd < 0) {		//	requested explicitly -> do NOT silently fall back
			fprintf(stderr, "[ETH-BACKEND] FATAL: +eth_tap=%s requested but TAP open "
					"failed; refusing to run the in-process responder instead\n",
					s ? s + 1 : "?");
			exit(1);
		}
	}
	if ((p = Verilated::commandArgsPlusMatch("eth_pcap="))[0]) {
		const char *s = strchr(p, '=');
		if (s) pcap_open(s + 1);
	}
	if (g_tap_fd >= 0)
		printf("[ETH-BACKEND] bridging guest <-> host TAP (no in-process responder)\n");
	else
		printf("[ETH-BACKEND] responder: server %u.%u.%u.%u mac %02x:%02x:%02x:%02x:%02x:%02x tftp_dir=%s\n",
			(g_ip>>24)&255,(g_ip>>16)&255,(g_ip>>8)&255,g_ip&255,
			g_mac[0],g_mac[1],g_mac[2],g_mac[3],g_mac[4],g_mac[5], g_tftp_dir);
	fflush(stdout);
}

void eth_dpi_tx_byte(unsigned char b)
{
	if (tx_len < FMAX) tx_buf[tx_len++] = b;
}

void eth_dpi_tx_eof(void)
{
	if (!g_inited) eth_backend_init();

	//	strip wire framing: skip up to+incl the SFD (0xD5), drop the 4-byte FCS.
	int i = 0;
	while (i < tx_len && tx_buf[i] == 0x55) i++;
	if (i < tx_len && tx_buf[i] == 0xD5) i++;
	const uint8_t *f = tx_buf + i;
	int flen = tx_len - i - 4;			//	minus FCS
	if (g_trace) {
		printf("[ETH-BACKEND] TX raw=%d strip_i=%d flen=%d et=%04x frame=",
			tx_len, i, flen, (flen >= 14 ? be16(f + 12) : 0));
		for (int k = 0; k < 42 && k < flen; k++) printf("%02x%s", f[k],
			(k==5||k==11||k==13)?"|":" ");
		printf("\n"); fflush(stdout);
	}
	tx_len = 0;
	if (flen < 14) return;				//	runt

	if (g_pcap) pcap_write(f, flen);
	if (g_tap_fd >= 0) {				//	TAP mode: hand the frame to the host
		if (write(g_tap_fd, f, flen) < 0 && g_verbose)
			perror("[ETH-BACKEND] tap write");
		return;
	}

	uint16_t et = be16(f + 12);			//	else: in-process responder
	if (et == 0x0806)      handle_arp(f, flen);
	else if (et == 0x0800) handle_ipv4(f, flen);
}

//	---- ARP: reply to a request for our IP ----
static void handle_arp(const uint8_t *f, int len)
{
	if (len < 42) return;
	const uint8_t *a = f + 14;			//	ARP payload
	uint32_t tip = be32(a + 24);		//	target protocol addr
	if (g_trace) printf("[ETH-BACKEND]  ARP op=%u target=%u.%u.%u.%u (ours=%u.%u.%u.%u)\n",
		be16(a + 6), (tip>>24)&255,(tip>>16)&255,(tip>>8)&255,tip&255,
		(g_ip>>24)&255,(g_ip>>16)&255,(g_ip>>8)&255,g_ip&255);
	if (be16(a + 6) != 1) return;		//	opcode != request
	if (tip != g_ip) return;

	uint8_t r[42];
	memcpy(r + 0, f + 6, 6);			//	dest = requester MAC
	memcpy(r + 6, g_mac, 6);			//	src  = us
	wbe16(r + 12, 0x0806);
	wbe16(r + 14, 1); wbe16(r + 16, 0x0800);
	r[18] = 6; r[19] = 4; wbe16(r + 20, 2);	//	hlen, plen, opcode=reply
	memcpy(r + 22, g_mac, 6);			//	sender = us
	wbe32(r + 28, g_ip);
	memcpy(r + 32, a + 8, 6);			//	target = requester
	wbe32(r + 38, be32(a + 14));
	queue_eth(r, 42);
	if (g_verbose) { printf("[ETH-BACKEND] ARP who-has %u.%u.%u.%u -> reply\n",
		(g_ip>>24)&255,(g_ip>>16)&255,(g_ip>>8)&255,g_ip&255); fflush(stdout); }
}

//	---- build an IPv4 packet (proto, payload) back to a peer ----
static void send_ipv4(const uint8_t *dmac, uint32_t dip, uint8_t proto,
					  const uint8_t *payload, int plen)
{
	uint8_t r[FMAX];
	memcpy(r + 0, dmac, 6);
	memcpy(r + 6, g_mac, 6);
	wbe16(r + 12, 0x0800);
	uint8_t *ip = r + 14;
	int tot = 20 + plen;
	ip[0] = 0x45; ip[1] = 0; wbe16(ip + 2, tot);
	wbe16(ip + 4, 0); wbe16(ip + 6, 0);		//	id, flags/frag
	ip[8] = 64; ip[9] = proto; wbe16(ip + 10, 0);
	wbe32(ip + 12, g_ip); wbe32(ip + 16, dip);
	wbe16(ip + 10, cksum16(ip, 20, 0));		//	header checksum
	memcpy(ip + 20, payload, plen);
	queue_eth(r, 14 + tot);
}

//	---- ICMP echo + UDP/TFTP ----
static void handle_udp(const uint8_t *f, const uint8_t *ip, int iplen);

static void handle_ipv4(const uint8_t *f, int len)
{
	const uint8_t *ip = f + 14;
	if (len < 14 + 20) return;
	int ihl = (ip[0] & 0xf) * 4;
	uint8_t proto = ip[9];
	uint32_t sip = be32(ip + 12);
	uint32_t dip = be32(ip + 16);
	if (dip != g_ip) return;

	if (proto == 1) {					//	ICMP
		const uint8_t *ic = ip + ihl;
		if (ic[0] != 8) return;			//	not echo request
		int iclen = be16(ip + 2) - ihl;
		uint8_t pl[FMAX];
		memcpy(pl, ic, iclen);
		pl[0] = 0;						//	echo reply
		wbe16(pl + 2, 0);
		wbe16(pl + 2, cksum16(pl, iclen, 0));
		send_ipv4(f + 6, sip, 1, pl, iclen);
		if (g_verbose) { printf("[ETH-BACKEND] ICMP echo -> reply\n"); fflush(stdout); }
	} else if (proto == 17) {			//	UDP
		handle_udp(f, ip, len - 14);
	}
}

//	---- TFTP read request / ack ----
static void handle_udp(const uint8_t *f, const uint8_t *ip, int iplen)
{
	int ihl = (ip[0] & 0xf) * 4;
	const uint8_t *udp = ip + ihl;
	uint16_t sport = be16(udp + 0);
	uint16_t dport = be16(udp + 2);
	uint16_t ulen  = be16(udp + 4);
	const uint8_t *data = udp + 8;
	int dlen = ulen - 8;
	uint32_t sip = be32(ip + 12);

	if (dport == 69 && dlen >= 2 && be16(data) == 1) {		//	TFTP RRQ
		const char *fn = (const char *)(data + 2);
		char path[1024];
		snprintf(path, sizeof(path), "%s/%s", g_tftp_dir, fn);
		if (tftp_fp) fclose(tftp_fp);
		tftp_fp = fopen(path, "rb");
		printf("[ETH-BACKEND] TFTP RRQ '%s' -> %s\n", fn, tftp_fp ? "open" : "NOT FOUND");
		fflush(stdout);
		memcpy(tftp_cli_mac, f + 6, 6);
		tftp_cli_ip = sip; tftp_cli_port = sport; tftp_block = 0;
		tftp_blksize = 512; tftp_oack = 0;
		if (!tftp_fp) {
			uint8_t e[32]; wbe16(e, 5); wbe16(e + 2, 1);	//	ERROR: file not found
			strcpy((char *)(e + 4), "nf");
			// reuse a UDP send via DATA path? send a minimal error
			// (U-Boot will just fail the transfer cleanly)
			uint8_t pl[40]; wbe16(pl,69); wbe16(pl+2,sport);
			wbe16(pl+4,8+6); wbe16(pl+6,0); memcpy(pl+8,e,6);
			send_ipv4(f + 6, sip, 17, pl, 8 + 6);
			return;
		}
		//	RFC 2347/2348 options: filename\0 mode\0 [opt\0 val\0]... -> OACK blksize
		{
			const char *p = fn, *end = (const char *)data + dlen;
			int req = 0;
			p += strnlen(p, end - p) + 1;				//	skip filename
			if (p < end) p += strnlen(p, end - p) + 1;		//	skip mode
			while (p + 1 < end) {
				const char *opt = p; p += strnlen(p, end - p) + 1;
				if (p >= end) break;
				const char *val = p; p += strnlen(p, end - p) + 1;
				if (!strcmp(opt, "blksize")) req = atoi(val);
			}
			if (req >= 8) {
				tftp_blksize = req > TFTP_MAXBLK ? TFTP_MAXBLK : req;
				uint8_t pl[8 + 2 + 24]; int o = 10;
				wbe16(pl + 8, 6);				//	OACK opcode
				o += sprintf((char *)pl + o, "blksize") + 1;
				o += sprintf((char *)pl + o, "%d", tftp_blksize) + 1;
				wbe16(pl + 0, 69); wbe16(pl + 2, sport);
				wbe16(pl + 4, o);  wbe16(pl + 6, 0);		//	UDP len, cksum 0
				send_ipv4(tftp_cli_mac, tftp_cli_ip, 17, pl, o);
				tftp_oack = 1;					//	await block-0 ACK
				printf("[ETH-BACKEND] TFTP OACK blksize=%d\n", tftp_blksize);
				fflush(stdout);
				return;
			}
		}
		tftp_send_block();
	} else if (dport != 0 && dlen >= 4 && be16(data) == 4 && tftp_fp) {	//	TFTP ACK
		int blk = be16(data + 2);
		if (tftp_oack && blk == 0) {				//	OACK acked -> first data block
			tftp_oack = 0;
			tftp_send_block();
		} else if (blk == tftp_block) {
			if (tftp_last_len < tftp_blksize) {			//	final (short) block acked
				printf("[ETH-BACKEND] TFTP done (%d blocks)\n", tftp_block);
				fflush(stdout);
				fclose(tftp_fp); tftp_fp = NULL;
			} else {
				tftp_send_block();						//	next
			}
		}
	}
}

static void tftp_send_block(void)
{
	uint8_t pl[8 + 4 + TFTP_MAXBLK];
	int n = (int)fread(pl + 4 + 8, 1, tftp_blksize, tftp_fp);
	tftp_last_len = n;
	tftp_block++;
	//	UDP header (src 69 -> client port) then TFTP DATA opcode+block
	wbe16(pl + 0, 69);
	wbe16(pl + 2, tftp_cli_port);
	wbe16(pl + 4, 8 + 4 + n);					//	UDP length
	wbe16(pl + 6, 0);							//	UDP checksum (0 = none)
	wbe16(pl + 8, 3);							//	TFTP DATA
	wbe16(pl + 10, tftp_block);
	send_ipv4(tftp_cli_mac, tftp_cli_ip, 17, pl, 8 + 4 + n);
	if ((tftp_block & 0x3ff) == 0) {			//	progress every 1024 blocks
		printf("[ETH-BACKEND] TFTP block %d\n", tftp_block);
		fflush(stdout);
	}
}

//	================= RX byte streamer (wire bytes -> DPI) =================
static int      rx_have = 0;	//	a frame is being clocked out
static int      rx_pos  = 0;	//	position within the wire stream
static int      rx_flen = 0;
static uint32_t rx_crc  = 0;
#define PRE 7
#define IFG 12

int eth_dpi_rx_byte(void)
{
	if (!g_inited) eth_backend_init();	//	attach TAP at sim start (carrier up)
	if (!rx_have) {
		//	TAP mode: pull a frame from the host into the queue when idle.
		if (g_tap_fd >= 0 && q_head == q_tail) {
			uint8_t buf[FMAX];
			int n = read(g_tap_fd, buf, FMAX);		//	non-blocking
			if (n >= 14) { if (g_pcap) pcap_write(buf, n); queue_eth(buf, n); }
		}
		if (q_head == q_tail) return -1;		//	nothing queued
		rx_flen = q_len[q_head];
		rx_crc  = crc32_eth(q_buf[q_head], rx_flen);
		rx_pos  = 0;
		rx_have = 1;
	}
	int p = rx_pos++;
	if (p < PRE)                 return 0x55;			//	preamble
	if (p == PRE)                return 0xD5;			//	SFD
	p -= (PRE + 1);
	if (p < rx_flen)             return q_buf[q_head][p];	//	frame
	p -= rx_flen;
	if (p < 4)                   return (rx_crc >> (p * 8)) & 0xff;	//	FCS (LE)
	p -= 4;
	if (p < IFG)                 return -1;				//	inter-frame gap
	//	frame fully emitted: pop and idle one more
	q_head = (q_head + 1) % MAXF;
	rx_have = 0;
	return -1;
}
