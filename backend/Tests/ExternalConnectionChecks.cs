using System.Xml.Linq;
using Utility.Files;

static class ExternalConnectionChecks
{
    public static void Run()
    {
        XElement xml = XElement.Parse("<Connection Name='中文外部连接' Type='File'><Description>保留中文说明</Description><RelativePath>数据.csv</RelativePath><AbsolutePath>/absent/数据.csv</AbsolutePath></Connection>");
        var loaded = ExternalConnectionBase.TryLoadFromXML(Path.GetTempPath(), xml, out var connection);
        if (!loaded || connection is not FileExternalConnection file || file.Name != "中文外部连接" || file.Description != "保留中文说明"
            || file.RelativePath != "数据.csv" || file.SaveXML().Element("Description")?.Value != "保留中文说明")
            throw new InvalidOperationException("External connection descriptions must roundtrip through the retained source.");
        var directory = new DirectoryExternalConnection(Path.GetTempPath());
        directory.LoadXML(XElement.Parse("<Connection Name='目录' Type='Directory'><Description>筛选文件</Description><SearchPattern>*.geojson</SearchPattern><Recurse>True</Recurse></Connection>"));
        if (directory.Description != "筛选文件" || directory.SearchPattern != "*.geojson" || !directory.Recurse)
            throw new InvalidOperationException("Directory connection settings must retain source semantics.");
        Console.WriteLine("Source external connection descriptions and directory settings roundtrip passed.");
    }
}
