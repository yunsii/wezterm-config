using System.Runtime.InteropServices;

namespace WezTerm.WindowsHostHelper;

[StructLayout(LayoutKind.Sequential)]
internal struct ProcessBasicInformation
{
    public IntPtr Reserved1;
    public IntPtr PebBaseAddress;
    public IntPtr Reserved2_0;
    public IntPtr Reserved2_1;
    public IntPtr UniqueProcessId;
    public IntPtr Reserved3;
}

[StructLayout(LayoutKind.Sequential)]
internal struct ProcessEnvironmentBlock
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2)]
    public byte[] Reserved1;
    public byte BeingDebugged;
    public byte Reserved2;
    public IntPtr Reserved3_0;
    public IntPtr Reserved3_1;
    public IntPtr Ldr;
    public IntPtr ProcessParameters;
}

[StructLayout(LayoutKind.Sequential)]
internal struct ProcessParameters
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
    public byte[] Reserved1;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)]
    public IntPtr[] Reserved2;
    public RemoteUnicodeString ImagePathName;
    public RemoteUnicodeString CommandLine;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RemoteUnicodeString
{
    public ushort Length;
    public ushort MaximumLength;
    public IntPtr Buffer;
}

[StructLayout(LayoutKind.Sequential)]
internal struct Input
{
    public uint Type;
    public InputUnion Union;
}

[StructLayout(LayoutKind.Explicit)]
internal struct InputUnion
{
    [FieldOffset(0)]
    public KeyboardInput Keyboard;
}

[StructLayout(LayoutKind.Sequential)]
internal struct KeyboardInput
{
    public ushort VirtualKey;
    public ushort ScanCode;
    public uint Flags;
    public uint Time;
    public IntPtr ExtraInfo;
}
