using System.Drawing;
internal static class DesktopTheme
{
    public static readonly Color Canvas = ColorTranslator.FromHtml("#F5F5F7");
    public static readonly Color Surface = Color.White;
    public static readonly Color Ink = ColorTranslator.FromHtml("#1D1D1F");
    public static readonly Color Muted = ColorTranslator.FromHtml("#6E6E73");
    public static readonly Color Border = ColorTranslator.FromHtml("#E5E5EA");
    public static readonly Color Accent = ColorTranslator.FromHtml("#007AFF");
    public static readonly Color AccentHover = ColorTranslator.FromHtml("#006FE6");
    public static readonly Color AccentPressed = ColorTranslator.FromHtml("#005FCC");
    public static readonly Color AccentSoft = ColorTranslator.FromHtml("#E4EEFB");
    public static readonly Color Success = ColorTranslator.FromHtml("#248A3D");
    public static readonly Color Warning = ColorTranslator.FromHtml("#946200");
    public static readonly Color Danger = ColorTranslator.FromHtml("#D12E2E");
    public const string UiFont = "Microsoft YaHei UI";
    public const string MonitorSvg = "<svg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'><rect x='3' y='4' width='18' height='13' rx='2' fill='none' stroke='currentColor' stroke-width='1.7'/><path d='M8 21h8M12 17v4' stroke='currentColor' stroke-width='1.7' stroke-linecap='round'/></svg>";
    public const string SettingsSvg = "<svg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'><g fill='none' stroke='currentColor' stroke-width='1.7' stroke-linecap='round'><path d='M4 6h16M4 12h16M4 18h16'/><circle cx='9' cy='6' r='2' fill='white'/><circle cx='16' cy='12' r='2' fill='white'/><circle cx='8' cy='18' r='2' fill='white'/></g></svg>";
    public const string LogSvg = "<svg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'><g fill='none' stroke='currentColor' stroke-width='1.7' stroke-linecap='round'><rect x='5' y='3' width='14' height='18' rx='2'/><path d='M9 8h6M9 12h6M9 16h4'/></g></svg>";
    public const string PlaySvg = "<svg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'><path d='M8 4.8c0-1 1-1.5 1.8-.9l11 7.1c.8.5.8 1.5 0 2l-11 7.1c-.8.6-1.8.1-1.8-.9z' fill='currentColor'/></svg>";
    public const string MoreSvg = "<svg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'><g fill='currentColor'><circle cx='5' cy='12' r='1.6'/><circle cx='12' cy='12' r='1.6'/><circle cx='19' cy='12' r='1.6'/></g></svg>";
}
