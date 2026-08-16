using System;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Program
{
    private const string AppName = "mpv-subhanallah";

    private static int Main()
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Title = AppName + " installer";

            string targetRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mpv");
            string scriptsDir = Path.Combine(targetRoot, "scripts");
            string optionsDir = Path.Combine(targetRoot, "script-opts");
            string targetScript = Path.Combine(scriptsDir, AppName + ".lua");
            string targetConfig = Path.Combine(optionsDir, AppName + ".conf");

            Console.WriteLine(AppName + " installer");
            Console.WriteLine("Only one provider is required: SubDL or OpenSubtitles.");
            Console.WriteLine("Leave API/account fields blank to configure them later from Settings (F7).");
            Console.WriteLine();

            Directory.CreateDirectory(scriptsDir);
            Directory.CreateDirectory(optionsDir);
            WriteEmbeddedScript(targetScript);

            bool writeConfig = true;
            if (File.Exists(targetConfig))
            {
                string replace = Read("Existing settings found. Replace them? [y/N]", "");
                writeConfig = replace.Equals("y", StringComparison.OrdinalIgnoreCase);
            }

            string settingsKey = "F7";
            if (writeConfig)
                settingsKey = WriteConfig(targetConfig);

            Console.WriteLine();
            Console.WriteLine("Installed to " + targetRoot);
            Console.WriteLine("Restart mpv. Open Settings with " + settingsKey + ".");
            Console.WriteLine("Press Enter to close.");
            Console.ReadLine();
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Installation failed: " + error.Message);
            Console.Error.WriteLine("Press Enter to close.");
            Console.ReadLine();
            return 1;
        }
    }

    private static string WriteConfig(string path)
    {
        string provider;
        do
        {
            provider = Read("Provider: subdl or opensubtitles", "subdl").ToLowerInvariant();
        }
        while (provider != "subdl" && provider != "opensubtitles");

        string subdlKey = "";
        string opensubtitlesKey = "";
        string opensubtitlesUsername = "";
        string opensubtitlesPassword = "";

        if (provider == "subdl")
        {
            Console.WriteLine("SubDL API key: https://subdl.com/developers");
            subdlKey = Read("SubDL API key", "");
        }
        else
        {
            Console.WriteLine("OpenSubtitles API key: https://www.opensubtitles.com/consumers");
            opensubtitlesKey = Read("OpenSubtitles API key", "");
            opensubtitlesUsername = Read("OpenSubtitles username (optional)", "");
            opensubtitlesPassword = Read("OpenSubtitles password (optional)", "");
        }

        string languages = Read("Subtitle languages, comma-separated", "en,tr");
        string fileKey = Read("File search key", "F5");
        string manualKey = Read("Manual search key", "F6");
        string settingsKey = Read("Settings key", "F7");

        File.WriteAllLines(path, new[]
        {
            "provider=" + provider,
            "api_key=" + subdlKey,
            "opensubtitles_api_key=" + opensubtitlesKey,
            "opensubtitles_username=" + opensubtitlesUsername,
            "opensubtitles_password=" + opensubtitlesPassword,
            "languages=" + languages,
            "key_search_file=" + fileKey,
            "key_search_manual=" + manualKey,
            "key_settings=" + settingsKey
        }, new UTF8Encoding(false));

        return settingsKey;
    }

    private static void WriteEmbeddedScript(string destination)
    {
        using (Stream input = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream("mpv-subhanallah.lua"))
        {
            if (input == null)
                throw new InvalidOperationException("Embedded Lua script is missing.");
            using (FileStream output = File.Create(destination))
                input.CopyTo(output);
        }
    }

    private static string Read(string prompt, string defaultValue)
    {
        Console.Write(prompt);
        if (!String.IsNullOrEmpty(defaultValue))
            Console.Write(" [" + defaultValue + "]");
        Console.Write(": ");
        string value = Console.ReadLine();
        return String.IsNullOrWhiteSpace(value) ? defaultValue : value.Trim();
    }
}
