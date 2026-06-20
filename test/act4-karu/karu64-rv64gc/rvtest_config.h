#define RVMODEL_PMP_GRAIN 4
#define RVMODEL_NUM_PMPS 0

#define D_SUPPORTED
#define F_SUPPORTED
#define ZAAMO_SUPPORTED
#define ZALRSC_SUPPORTED
#define ZCA_SUPPORTED
#define ZCD_SUPPORTED
/* karu64 implements no hpmcounters (Zihpm not claimed in the UDB config),
   so ZIHPM_SUPPORTED is intentionally omitted. */

/* Vector integer subset (Zve64x): VLEN=256, ELEN=64. No vector FP. */
#define VLEN        256
#define SEWMIN        8
#define ELEN         64
#define MAXINDEXEEW  64
#define ZVL32B_SUPPORTED
#define ZVL64B_SUPPORTED
#define ZVL128B_SUPPORTED
#define ZVL256B_SUPPORTED
#define LMULf8_SUPPORTED
#define LMULf4_SUPPORTED
#define LMULf2_SUPPORTED
