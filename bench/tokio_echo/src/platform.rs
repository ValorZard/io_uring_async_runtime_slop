//! The three things the comparison needs from the operating system, and the
//! only three places the tokio side is not portable.
//!
//! Each one exists so the tokio binaries are measured under the same
//! conditions as the Ada ones, not because tokio needs it:
//!
//!   * `pin_to` puts a worker thread on one core, which is what the Ada
//!     runtime does for every shard.  Without it tokio's workers migrate and
//!     the two are not being asked the same question.
//!
//!   * `raise_descriptor_limit` matches `Iour.Ffi.Sys.Raise_Descriptor_Limit`.
//!     It is real work on Linux and a constant on Windows, which has no
//!     per-process handle limit worth raising.
//!
//!   * `listener_with_backlog` matches `Iour.Ffi.Net.Tcp_Listener`'s 4096.
//!     A short accept queue is the difference between a connect and a
//!     one-second SYN retransmit when a thousand clients arrive at once, and
//!     `TcpListener::bind` would give us 128.

use tokio::net::TcpListener;

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------

#[cfg(unix)]
mod imp {
    use super::TcpListener;

    pub fn pin_to(cpu: usize) {
        unsafe {
            let mut set: libc::cpu_set_t = std::mem::zeroed();
            libc::CPU_ZERO(&mut set);
            libc::CPU_SET(cpu, &mut set);
            libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
        }
    }

    pub fn raise_descriptor_limit() -> u64 {
        unsafe {
            let mut lim: libc::rlimit = std::mem::zeroed();
            if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) == 0 {
                lim.rlim_cur = lim.rlim_max;
                libc::setrlimit(libc::RLIMIT_NOFILE, &lim);
                return lim.rlim_max as u64;
            }
            0
        }
    }

    pub fn listener_with_backlog(port: u16, backlog: i32) -> std::io::Result<TcpListener> {
        use std::os::fd::FromRawFd;
        unsafe {
            let fd = libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0);
            if fd < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let on: libc::c_int = 1;
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_REUSEADDR,
                &on as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );

            let addr = libc::sockaddr_in {
                sin_family: libc::AF_INET as libc::sa_family_t,
                sin_port: port.to_be(),
                sin_addr: libc::in_addr { s_addr: 0 },
                sin_zero: [0; 8],
            };
            if libc::bind(
                fd,
                &addr as *const _ as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            ) < 0
            {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            if libc::listen(fd, backlog) < 0 {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }

            let std_listener = std::net::TcpListener::from_raw_fd(fd);
            std_listener.set_nonblocking(true)?;
            TcpListener::from_std(std_listener)
        }
    }
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod imp {
    use super::TcpListener;

    type Handle = isize;
    type Socket = usize;

    const INVALID_SOCKET: Socket = usize::MAX;
    const AF_INET: i32 = 2;
    const SOCK_STREAM: i32 = 1;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_REUSEADDR: i32 = 0x0004;
    const FIONBIO: u32 = 0x8004_667E;
    const SOMAXCONN: i32 = 0x7FFF_FFFF;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentThread() -> Handle;
        fn SetThreadAffinityMask(thread: Handle, mask: usize) -> usize;
    }

    #[repr(C)]
    struct SockaddrIn {
        family: u16,
        port: u16,
        addr: u32,
        zero: [u8; 8],
    }

    #[repr(C)]
    struct WsaData {
        version: u16,
        high_version: u16,
        description: [u8; 257],
        system_status: [u8; 129],
        max_sockets: u16,
        max_udp_dg: u16,
        vendor_info: *mut u8,
    }

    #[link(name = "ws2_32")]
    extern "system" {
        fn WSAStartup(version: u16, data: *mut WsaData) -> i32;
        fn socket(af: i32, kind: i32, protocol: i32) -> Socket;
        fn bind(s: Socket, name: *const SockaddrIn, namelen: i32) -> i32;
        fn listen(s: Socket, backlog: i32) -> i32;
        fn setsockopt(s: Socket, level: i32, name: i32, val: *const u8, len: i32) -> i32;
        fn ioctlsocket(s: Socket, cmd: u32, arg: *mut u32) -> i32;
        fn closesocket(s: Socket) -> i32;
    }

    /// The Ada runtime pins each shard with `SetThreadAffinityMask` too --
    /// GNAT for Windows accepts Ada's `CPU` aspect and ignores it, so both
    /// sides of this comparison ask for their core the same way.
    pub fn pin_to(cpu: usize) {
        if cpu >= usize::BITS as usize {
            return;
        }
        unsafe {
            SetThreadAffinityMask(GetCurrentThread(), 1usize << cpu);
        }
    }

    /// Windows has no per-process handle rlimit to raise: the ceiling is
    /// 16,777,216 handles, set by the kernel and not adjustable.  Reporting
    /// it keeps the banner comparable with the Ada server's.
    pub fn raise_descriptor_limit() -> u64 {
        16_777_216
    }

    pub fn listener_with_backlog(port: u16, backlog: i32) -> std::io::Result<TcpListener> {
        use std::os::windows::io::FromRawSocket;
        unsafe {
            // Winsock is reference counted, so starting it here is safe even
            // though the standard library will start it again for itself.
            let mut data: WsaData = std::mem::zeroed();
            WSAStartup(0x0202, &mut data);

            let s = socket(AF_INET, SOCK_STREAM, 0);
            if s == INVALID_SOCKET {
                return Err(std::io::Error::last_os_error());
            }
            let on: i32 = 1;
            setsockopt(
                s,
                SOL_SOCKET,
                SO_REUSEADDR,
                &on as *const i32 as *const u8,
                std::mem::size_of::<i32>() as i32,
            );

            let addr = SockaddrIn {
                family: AF_INET as u16,
                port: port.to_be(),
                addr: 0,
                zero: [0; 8],
            };
            if bind(s, &addr, std::mem::size_of::<SockaddrIn>() as i32) != 0 {
                let e = std::io::Error::last_os_error();
                closesocket(s);
                return Err(e);
            }
            // Windows reads SOMAXCONN as "use the largest backlog this
            // provider will give", and silently clamps any number to a
            // system maximum that is 200 on client editions -- far below
            // the 4096 every server here asks for.  Passing the number
            // through would measure that clamp rather than the runtime.
            let depth = if backlog > 200 { SOMAXCONN } else { backlog };
            if listen(s, depth) != 0 {
                let e = std::io::Error::last_os_error();
                closesocket(s);
                return Err(e);
            }
            let mut nonblocking: u32 = 1;
            ioctlsocket(s, FIONBIO, &mut nonblocking);

            let std_listener = std::net::TcpListener::from_raw_socket(s as u64);
            TcpListener::from_std(std_listener)
        }
    }
}

pub use imp::{listener_with_backlog, pin_to, raise_descriptor_limit};
