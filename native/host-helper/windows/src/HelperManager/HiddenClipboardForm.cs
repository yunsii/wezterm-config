using System.Drawing;
using System.Windows.Forms;

namespace WezTerm.WindowsHostHelper;

internal sealed class HiddenClipboardForm : Form
{
    public HiddenClipboardForm(ClipboardService service)
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(1, 1);
        Location = new Point(-32000, -32000);
        Opacity = 0;
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(false);
    }
}
