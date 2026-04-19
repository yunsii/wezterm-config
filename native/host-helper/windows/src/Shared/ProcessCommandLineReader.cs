namespace WezTerm.WindowsHostHelper;

internal static class ProcessCommandLineReader
{
    private const uint ProcessQueryInformation = 0x0400;
    private const uint ProcessVmRead = 0x0010;

    public static string? TryGetCommandLine(int processId)
    {
        IntPtr processHandle = IntPtr.Zero;
        try
        {
            processHandle = NativeMethods.OpenProcess(ProcessQueryInformation | ProcessVmRead, false, (uint)processId);
            if (processHandle == IntPtr.Zero)
            {
                return null;
            }

            var processInformation = NativeMethods.QueryBasicInformation(processHandle);
            var peb = NativeMethods.ReadStruct<ProcessEnvironmentBlock>(processHandle, processInformation.PebBaseAddress);
            if (peb.ProcessParameters == IntPtr.Zero)
            {
                return null;
            }

            var parameters = NativeMethods.ReadStruct<ProcessParameters>(processHandle, peb.ProcessParameters);
            if (parameters.CommandLine.Buffer == IntPtr.Zero || parameters.CommandLine.Length <= 0)
            {
                return null;
            }

            return NativeMethods.ReadUnicodeString(processHandle, parameters.CommandLine);
        }
        catch
        {
            return null;
        }
        finally
        {
            if (processHandle != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(processHandle);
            }
        }
    }
}
