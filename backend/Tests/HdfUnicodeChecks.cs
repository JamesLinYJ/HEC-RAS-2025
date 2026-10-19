using System.Text;
using Utility.Memory;
using H5Assist;
using H5Assist.Identifiers;

internal static class HdfUnicodeChecks
{
    internal static void Run()
    {
        using var folder = new TemporaryDirectory();
        string path = Path.Combine(folder.FullName, "中文表格.h5");
        string[] strings = ["中文连接", "路径/🌊.tif", "ASCII", ""];
        using (var writer = new H5Writer(path))
        {
            writer.CreateGroup("/中文组");
            writer.WriteAttribute("/中文组", "中文属性", "中文属性值🌊");
            writer.WriteAttribute("/中文组", "属性数组", strings);
            writer.WriteDataset("/中文组/定长数组", strings);
            writer.WriteVariableLenStringArray("/中文组/变长数组", strings);
            writer.WriteDataset("/中文组/二维", new string[,] { { "中文", "🌊" }, { "longer ASCII", "" } });
            var table = new Table(); table.AddColumn("中文列", typeof(string)); table.AddColumn("相邻数字", typeof(int));
            table.AddNewRow(["路径与分类🌊", 12345678]); table.AddNewRow(["ASCII", -31]);
            writer.WriteCompoundTable("/中文组/复合表", table);
            var type = new CompoundTypeDefinition(); type.AddStringField("受限字段", 5); type.AddField<int>("相邻字段");
            writer.Create1DCompoundDataset("/中文组/定长复合", 2, type);
            using var columns = new CompoundWriter(writer, "/中文组/定长复合", 2);
            columns.WriteColumn(0, new string[] { "中文", "🌊中" });
            columns.WriteColumn(1, new int[] { 12345678, -31 });
        }
        using (var reader = new H5Reader(path))
        {
            Check(reader.TryReadStringAttributeScalar("/中文组", "中文属性") == "中文属性值🌊", "UTF8 scalar attribute retains text");
            Check(reader.GetAttributeNames("/中文组").Contains("中文属性"), "UTF8 attribute names enumerate without replacement");
            reader.ReadDataset("/中文组/定长数组", out string[] fixedValues);
            reader.ReadAttribute("/中文组", "属性数组", out string[] attributeValues);
            reader.ReadDataset("/中文组/变长数组", out string[] variableValues);
            Check(fixedValues.SequenceEqual(strings) && variableValues.SequenceEqual(strings) && attributeValues.SequenceEqual(strings), "UTF8 fixed, variable and attribute arrays retain values and offsets");
            using var matrix = H5DatasetID.Open(reader.H5FileID, "/中文组/二维", needType: true, needSpace: true);
            reader.ReadDataset(matrix, out string[,] values);
            Check(values[0, 0] == "中文" && values[0, 1] == "🌊" && values[1, 0] == "longer ASCII" && values[1, 1] == "", "UTF8 matrix row/column layout is preserved");
            var table = reader.ReadCompoundElementsAsTable("/中文组/复合表");
            Check((string)table[0][0] == "路径与分类🌊" && (int)table[0][1] == 12345678 && (int)table[1][1] == -31, "UTF8 compound byte widths preserve adjacent values");
            var bounded = reader.ReadCompoundElementsAsTable("/中文组/定长复合");
            Check((string)bounded[0][0] == "中" && (string)bounded[1][0] == "🌊" && (int)bounded[0][1] == 12345678 && (int)bounded[1][1] == -31, "Fixed byte fields truncate complete scalars without overwriting adjacent columns");
        }
        byte[] bytes = new byte[5]; H5StringEncoding.WriteFixed("🌊中文", bytes);
        Check(new UTF8Encoding(false, true).GetString(bytes).TrimEnd('\0') == "🌊", "Truncation creates valid UTF8");
        Console.WriteLine("Actual UTF8 HDF attributes, names, fixed/variable arrays, matrix, compound fields and scalar-boundary truncation passed.");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
