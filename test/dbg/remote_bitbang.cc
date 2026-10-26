// Bounded remote_bitbang server for the Verilated transport/DM fixture.
// SPDX-License-Identifier: BSD-2-Clause
#ifdef KARUDBG_BSCAN_TARGET
#include "Vtb_bscan_remote.h"
using DebugModel = Vtb_bscan_remote;
#elif defined(KARUDBG_CORE_TARGET)
#include "Vtb_jtag_core.h"
using DebugModel = Vtb_jtag_core;
#else
#include "Vtb_jtag_remote.h"
using DebugModel = Vtb_jtag_remote;
#endif
#include "verilated.h"
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

int main(int argc,char **argv) {
    VerilatedContext context;
    context.commandArgs(argc,argv);
    DebugModel top(&context);
    auto step = [&]() {
        top.clk=0; top.eval(); context.timeInc(1);
        top.clk=1; top.eval(); context.timeInc(1);
    };
    auto clocks = [&](int n) {for(int i=0;i<n;i++) step();};
    top.rst=1; top.trst_n=0; top.tck=0; top.tms=1; top.tdi=0;
#ifdef KARUDBG_CORE_TARGET
    top.hart_reset=0;
#endif
    clocks(16); top.rst=0; top.trst_n=1; clocks(16);
    int listener=socket(AF_INET,SOCK_STREAM,0);
    if(listener<0) {perror("socket");return 1;}
    int one=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    sockaddr_in address{}; address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    address.sin_port=htons(argc>1 ? std::atoi(argv[1]) : 0);
    if(bind(listener,reinterpret_cast<sockaddr *>(&address),sizeof(address))<0 || listen(listener,1)<0) {
        perror("bind/listen");return 1;
    }
    socklen_t length=sizeof(address);
    getsockname(listener,reinterpret_cast<sockaddr *>(&address),&length);
    std::printf("REMOTE_BITBANG_PORT=%u\n",ntohs(address.sin_port)); std::fflush(stdout);
    pollfd incoming{listener,POLLIN,0};
    if(poll(&incoming,1,15000)<=0) {std::fprintf(stderr,"No OpenOCD connection\n");return 1;}
    int client=accept(listener,nullptr,nullptr); close(listener);
    setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    const auto deadline=std::chrono::steady_clock::now()+
        std::chrono::seconds(argc>2 ? std::atoi(argv[2]):25);
    bool quit=false;
    while(!quit && std::chrono::steady_clock::now()<deadline) {
        pollfd descriptor{client,POLLIN,0};
        int available=poll(&descriptor,1,1);
        if(available<0) {perror("poll");return 1;}
        if(available==0) {clocks(10);continue;}
        char commands[2048];
        ssize_t count=read(client,commands,sizeof(commands));
        if(count<=0) break;
        for(ssize_t i=0;i<count;i++) {
            char command=commands[i];
            if(command>='0' && command<='7') {
                unsigned bits=command-'0';
                top.tck=(bits>>2)&1; top.tms=(bits>>1)&1; top.tdi=bits&1;
                top.eval(); clocks(2);
            } else if(command=='R') {
                char bit=top.tdo ? '1':'0';
                if(send(client,&bit,1,MSG_NOSIGNAL)!=1) {perror("send");return 1;}
            } else if(command>='r' && command<='u') {
                unsigned bits=command-'r';
                top.trst_n=(bits&2)==0;
                // SRST is the hart-only reset on a real target. This fixture
                // has no hart, so it must not reset the debug module/transport.
#ifdef KARUDBG_CORE_TARGET
                top.hart_reset=bits&1;
#endif
                top.eval(); clocks(8);
            } else if(command=='z' || command=='Z') {
                clocks(command=='z' ? 10:1000);
            } else if(command=='Q') quit=true;
            else if(command!='B' && command!='b') {
                std::fprintf(stderr,"Bad remote_bitbang command 0x%02x\n",static_cast<unsigned char>(command));
                return 1;
            }
        }
    }
    close(client);
    top.final();
#ifdef KARUDBG_CORE_TARGET
    std::printf("Core debug PC=%016llx parked=%u\n",static_cast<unsigned long long>(top.debug_pc),top.debug_parked);
#endif
    if(!quit || top.request_count<12) {
        std::fprintf(stderr,"Transport test incomplete: quit=%d DMI requests=%u\n",quit,top.request_count);
        return 1;
    }
    std::printf("PASS remote_bitbang DMI requests=%u\n",top.request_count);
    return 0;
}
