using System;
using System.IO;

namespace Ras.Engine.Structures;

public static class StructureTSLogger
{
	private static readonly object _lock;

	private static StreamWriter _writer;

	static StructureTSLogger()
	{
		_lock = new object();
		OpenNewLogFile();
	}

	private static void OpenNewLogFile()
	{
		string now = DateTime.Now.ToString("yyyyMMdd_HHmmss");
		_writer = new StreamWriter(Path.Combine("C:\\Temp", "struct_ts_" + now + ".log"), append: false)
		{
			AutoFlush = true
		};
	}

	public static void Log(string message)
	{
		lock (_lock)
		{
			_writer?.WriteLine(message);
		}
	}

	public static void RotateLog()
	{
		lock (_lock)
		{
			_writer?.Close();
			OpenNewLogFile();
		}
	}

	public static void Close()
	{
		lock (_lock)
		{
			_writer?.Close();
			_writer = null;
		}
	}
}
