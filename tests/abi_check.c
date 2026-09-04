/*  abi_check -- pin the Ada mirrors of the kernel ABI to the real headers.
 *
 *  Iour.Ffi.Uring and Iour.Ffi.Net describe struct io_uring_sqe,
 *  struct io_uring_cqe, struct io_uring_params and struct sockaddr_in in
 *  Ada, with explicit representation clauses.  Those structures are kernel
 *  UAPI and so are frozen, which is exactly why mirroring them is safe --
 *  but "safe because it is frozen" is worth checking rather than trusting.
 *
 *  Every assertion below is compile-time.  If a field ever moves, or an
 *  opcode is renumbered, this file stops compiling and the build fails
 *  rather than the runtime quietly submitting malformed entries.
 *
 *  Build and run:  make abi-check
 */
#define _GNU_SOURCE
#include <liburing.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <stddef.h>
#include <stdio.h>

#define CHECK(cond, msg) _Static_assert(cond, msg)

/* ---- struct io_uring_sqe, as mirrored by Iour.Ffi.Uring.Sqe ------------- */
CHECK(sizeof(struct io_uring_sqe) == 64,          "Sqe size");
CHECK(offsetof(struct io_uring_sqe, opcode) == 0, "Sqe.Opcode at 0");
CHECK(offsetof(struct io_uring_sqe, flags) == 1,  "Sqe.Flags at 1");
CHECK(offsetof(struct io_uring_sqe, ioprio) == 2, "Sqe.Ioprio at 2");
CHECK(offsetof(struct io_uring_sqe, fd) == 4,     "Sqe.Fd at 4");
CHECK(offsetof(struct io_uring_sqe, off) == 8,    "Sqe.Off at 8");
CHECK(offsetof(struct io_uring_sqe, addr) == 16,  "Sqe.Addr at 16");
CHECK(offsetof(struct io_uring_sqe, len) == 24,   "Sqe.Len at 24");
CHECK(offsetof(struct io_uring_sqe, user_data) == 32, "Sqe.User_Data at 32");
CHECK(offsetof(struct io_uring_sqe, buf_index) == 40, "Sqe.Buf_Index at 40");
CHECK(offsetof(struct io_uring_sqe, personality) == 42,
      "Sqe.Personality at 42");
CHECK(offsetof(struct io_uring_sqe, file_index) == 44,
      "Sqe.Splice_Fd_In doubles as file_index at 44");

/* ---- registered files --------------------------------------------------- */
CHECK(sizeof(struct io_uring_files_update) == 16, "Files_Update size");
CHECK(offsetof(struct io_uring_files_update, offset) == 0,
      "Files_Update.Offset at 0");
CHECK(offsetof(struct io_uring_files_update, fds) == 8,
      "Files_Update.Fds at 8");

/* ---- struct io_uring_cqe, as mirrored by Iour.Ffi.Uring.Cqe ------------- */
CHECK(sizeof(struct io_uring_cqe) == 16,              "Cqe size");
CHECK(offsetof(struct io_uring_cqe, user_data) == 0,  "Cqe.User_Data at 0");
CHECK(offsetof(struct io_uring_cqe, res) == 8,        "Cqe.Res at 8");
CHECK(offsetof(struct io_uring_cqe, flags) == 12,     "Cqe.Flags at 12");

/* ---- struct io_uring_params, as mirrored by Iour.Ffi.Uring.Params ------ */
CHECK(sizeof(struct io_uring_params) == 120,           "Params size");
CHECK(offsetof(struct io_uring_params, sq_off) == 40,  "Params.Sq_Off at 40");
CHECK(offsetof(struct io_uring_params, cq_off) == 80,  "Params.Cq_Off at 80");

/* ---- struct sockaddr_in, as mirrored by Iour.Ffi.Net.Sockaddr_In ------- */
CHECK(sizeof(struct sockaddr_in) == 16,                "Sockaddr_In size");
CHECK(offsetof(struct sockaddr_in, sin_family) == 0,   "sin_family at 0");
CHECK(offsetof(struct sockaddr_in, sin_port) == 2,     "sin_port at 2");
CHECK(offsetof(struct sockaddr_in, sin_addr) == 4,     "sin_addr at 4");

/* ---- opcodes and flags named in Iour.Ffi.Uring -------------------------- */
CHECK(IORING_OP_NOP == 0,       "Op_Nop");
CHECK(IORING_OP_TIMEOUT == 11,  "Op_Timeout");
CHECK(IORING_OP_ACCEPT == 13,   "Op_Accept");
CHECK(IORING_OP_CONNECT == 16,  "Op_Connect");
CHECK(IORING_OP_CLOSE == 19,    "Op_Close");
CHECK(IORING_OP_SEND == 26,     "Op_Send");
CHECK(IORING_OP_RECV == 27,     "Op_Recv");
CHECK(IORING_OP_MSG_RING == 40, "Op_Msg_Ring");

CHECK(IORING_OFF_SQ_RING == 0,             "Off_Sq_Ring");
CHECK(IORING_OFF_CQ_RING == 0x8000000ULL,  "Off_Cq_Ring");
CHECK(IORING_OFF_SQES == 0x10000000ULL,    "Off_Sqes");

CHECK(IORING_SETUP_SQPOLL == 2,          "Setup_Sqpoll");
CHECK(IORING_SETUP_CLAMP == 16,          "Setup_Clamp");
CHECK(IORING_SETUP_COOP_TASKRUN == 256,  "Setup_Coop_Taskrun");
CHECK(IORING_SETUP_SINGLE_ISSUER == 4096, "Setup_Single_Issuer");
CHECK(IORING_SETUP_DEFER_TASKRUN == 8192, "Setup_Defer_Taskrun");

CHECK(IORING_FEAT_SINGLE_MMAP == 1, "Feat_Single_Mmap");
CHECK(IORING_FEAT_NODROP == 2,      "Feat_Nodrop");
CHECK(IORING_ENTER_GETEVENTS == 1,  "Enter_Getevents");
CHECK(IORING_SQ_NEED_WAKEUP == 1,   "Sq_Need_Wakeup");
CHECK(IORING_CQE_F_MORE == 2,       "Cqe_F_More");
CHECK(IOSQE_CQE_SKIP_SUCCESS == 64, "Sqe_Cqe_Skip_Success");
CHECK(IOSQE_FIXED_FILE == 1,        "Sqe_Fixed_File");
CHECK(IORING_FILE_INDEX_ALLOC == (__u32) -1, "File_Index_Alloc");
CHECK(IORING_REGISTER_FILES == 2,          "Register_Files");
CHECK(IORING_REGISTER_FILES_UPDATE == 6,   "Register_Files_Update");

/* ---- socket constants named in Iour.Ffi.Net ---------------------------- */
CHECK(AF_INET == 2,        "Af_Inet");
CHECK(SOCK_STREAM == 1,    "Sock_Stream");
CHECK(SOL_SOCKET == 1,     "Sol_Socket");
CHECK(SO_REUSEADDR == 2,   "So_Reuseaddr");
CHECK(SO_REUSEPORT == 15,  "So_Reuseport");
CHECK(IPPROTO_TCP == 6,    "Ipproto_Tcp");
CHECK(TCP_NODELAY == 1,    "Tcp_Nodelay");
CHECK(MSG_NOSIGNAL == 0x4000, "Msg_Nosignal");

int main(void)
{
    puts("abi_check: every Ada mirror of the kernel ABI matches this "
         "system's headers");
    return 0;
}
