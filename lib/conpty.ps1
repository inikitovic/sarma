# lib/conpty.ps1 — Windows ConPTY (Pseudo Console) wrapper
# Provides headless interactive terminal control without window focus

if (-not ([System.Management.Automation.PSTypeName]'SarmaConPty').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class SarmaConPty : IDisposable
{
    private IntPtr _hPC;
    private IntPtr _hProcess;
    private IntPtr _hThread;
    private IntPtr _writePipe;
    private IntPtr _readPipe;
    private int _pid;
    private bool _disposed;

    // ── Win32 structs ──────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    // ── Win32 constants ────────────────────────────────────────

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
    const uint STILL_ACTIVE = 259;

    // ── Win32 imports ──────────────────────────────────────────

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite,
        ref SECURITY_ATTRIBUTES sa, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput,
        IntPtr hOutput, uint flags, out IntPtr phPC);

    [DllImport("kernel32.dll")]
    static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttrList,
        int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttrList, uint flags,
        IntPtr attr, IntPtr val, IntPtr cbSize, IntPtr prev, IntPtr retSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttrList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmdLine,
        IntPtr procAttr, IntPtr threadAttr, bool inherit, uint flags,
        IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr hFile, byte[] buf, uint len,
        out uint written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr hFile, [Out] byte[] buf, uint len,
        out uint read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool PeekNamedPipe(IntPtr hPipe, IntPtr buf, uint bufSize,
        IntPtr bytesRead, out uint totalAvail, IntPtr bytesLeft);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll")]
    static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    [DllImport("kernel32.dll")]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll")]
    static extern bool TerminateProcess(IntPtr h, uint code);

    // ── Properties ─────────────────────────────────────────────

    public int ProcessId { get { return _pid; } }

    public bool HasExited {
        get {
            if (_hProcess == IntPtr.Zero) return true;
            uint code;
            GetExitCodeProcess(_hProcess, out code);
            return code != STILL_ACTIVE;
        }
    }

    public int ExitCode {
        get {
            if (_hProcess == IntPtr.Zero) return -1;
            uint code;
            GetExitCodeProcess(_hProcess, out code);
            return (int)code;
        }
    }

    // ── Public API ─────────────────────────────────────────────

    public void Start(string commandLine, string workDir, short cols = 120, short rows = 30)
    {
        // Create two pipe pairs: input (we write → PTY reads) and output (PTY writes → we read)
        var sa = new SECURITY_ATTRIBUTES {
            nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
            bInheritHandle = true
        };

        IntPtr ptyInRead, ptyInWrite, ptyOutRead, ptyOutWrite;
        if (!CreatePipe(out ptyInRead, out ptyInWrite, ref sa, 0))
            throw new Exception("CreatePipe(input) failed, error " + Marshal.GetLastWin32Error());
        if (!CreatePipe(out ptyOutRead, out ptyOutWrite, ref sa, 0))
            throw new Exception("CreatePipe(output) failed, error " + Marshal.GetLastWin32Error());

        // Keep our ends of the pipes
        _writePipe = ptyInWrite;   // we write commands here
        _readPipe  = ptyOutRead;   // we read terminal output here

        // Create the pseudo console
        var size = new COORD { X = cols, Y = rows };
        int hr = CreatePseudoConsole(size, ptyInRead, ptyOutWrite, 0, out _hPC);
        if (hr != 0)
            throw new Exception("CreatePseudoConsole failed, HRESULT 0x" + hr.ToString("X8"));

        // PTY now owns the other pipe ends — close ours
        CloseHandle(ptyInRead);
        CloseHandle(ptyOutWrite);

        // Build process attribute list with pseudo console
        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);

        if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize))
            throw new Exception("InitializeProcThreadAttributeList failed, error " + Marshal.GetLastWin32Error());

        if (!UpdateProcThreadAttribute(attrList, 0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, _hPC,
                (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("UpdateProcThreadAttribute failed, error " + Marshal.GetLastWin32Error());

        // Launch the process inside the pseudo console
        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
        si.lpAttributeList = attrList;

        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, workDir, ref si, out pi))
            throw new Exception("CreateProcess failed, error " + Marshal.GetLastWin32Error());

        _hProcess = pi.hProcess;
        _hThread  = pi.hThread;
        _pid      = pi.dwProcessId;

        // Cleanup attribute list (process already using the PTY)
        DeleteProcThreadAttributeList(attrList);
        Marshal.FreeHGlobal(attrList);
    }

    /// <summary>Write text to the terminal input (as if typed by user)</summary>
    public void Write(string text)
    {
        if (_writePipe == IntPtr.Zero) return;
        byte[] data = Encoding.UTF8.GetBytes(text);
        uint written;
        if (!WriteFile(_writePipe, data, (uint)data.Length, out written, IntPtr.Zero))
            throw new Exception("WriteFile failed, error " + Marshal.GetLastWin32Error());
    }

    /// <summary>Read terminal output with timeout (includes ANSI escape sequences)</summary>
    public string Read(int timeoutMs = 1000)
    {
        if (_readPipe == IntPtr.Zero) return "";
        var sb = new StringBuilder();
        byte[] buf = new byte[8192];
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);

        while (DateTime.UtcNow < deadline) {
            uint avail;
            if (PeekNamedPipe(_readPipe, IntPtr.Zero, 0, IntPtr.Zero, out avail, IntPtr.Zero)
                && avail > 0) {
                uint read;
                uint toRead = Math.Min(avail, (uint)buf.Length);
                if (ReadFile(_readPipe, buf, toRead, out read, IntPtr.Zero) && read > 0)
                    sb.Append(Encoding.UTF8.GetString(buf, 0, (int)read));
            } else {
                Thread.Sleep(50);
            }
        }
        return sb.ToString();
    }

    /// <summary>Wait for the process to exit</summary>
    public void WaitForExit(int timeoutMs = -1)
    {
        if (_hProcess == IntPtr.Zero) return;
        WaitForSingleObject(_hProcess, timeoutMs < 0 ? 0xFFFFFFFF : (uint)timeoutMs);
    }

    /// <summary>Force-kill the process</summary>
    public void Kill()
    {
        if (_hProcess != IntPtr.Zero && !HasExited)
            TerminateProcess(_hProcess, 1);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // Close pseudo console first (signals child to exit)
        if (_hPC != IntPtr.Zero)        { ClosePseudoConsole(_hPC); _hPC = IntPtr.Zero; }
        if (_writePipe != IntPtr.Zero)  { CloseHandle(_writePipe); _writePipe = IntPtr.Zero; }
        if (_readPipe != IntPtr.Zero)   { CloseHandle(_readPipe); _readPipe = IntPtr.Zero; }
        if (_hThread != IntPtr.Zero)    { CloseHandle(_hThread); _hThread = IntPtr.Zero; }
        if (_hProcess != IntPtr.Zero)   { CloseHandle(_hProcess); _hProcess = IntPtr.Zero; }
    }
}
'@ -ErrorAction Stop
}
