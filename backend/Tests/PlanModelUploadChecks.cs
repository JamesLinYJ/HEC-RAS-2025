using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Ras.Backend;
using Utility.Progress;

internal static class PlanModelUploadChecks
{
    internal static async Task VerifyCommittedReceipt(PlanExportResult receipt)
    {
        int pushes = 0;
        var request = new PlanModelUploadRequest(receipt, receipt.ProjectSessionID,
            "offline-model-zip-receipt", "offline-owner", "offline-access", "offline-secret",
            receipt.ProjectPath, receipt.PlanPath, receipt.SourceRevision, receipt.ReceiptID);
        PlanModelUploadResult result = await Execute(request, (_, _) => new FakeUploader((modelID, path, owner, _) =>
        {
            Check(modelID == request.ModelID && path == receipt.OutputPath && owner == request.Owner,
                "The real committed plan ZIP is uploaded only with its captured identity.");
            pushes++;
            return Task.CompletedTask;
        }));
        Check(pushes == 1 && result.State == "completed" && result.ReceiptID == receipt.ReceiptID,
            "A receipt produced by a real local PlanExportService ZIP commit passes the offline upload boundary.");
    }

    internal static async Task Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "plan-model-upload-checks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Scenario scenario = CreateScenario(root);
            int factoryCalls = 0;
            FakeUploader success = new((modelID, path, owner, _) =>
            {
                Check(modelID == "offline-model-42", "The exact model ID reaches the uploader.");
                Check(path == scenario.Receipt.OutputPath, "Only the committed ZIP path reaches the uploader.");
                Check(owner == "offline-owner", "The application owner identity reaches the uploader.");
                return Task.CompletedTask;
            });
            PlanModelUploadResult completed = await Execute(scenario.Request, (_, _) =>
            {
                factoryCalls++;
                return success;
            });
            Check(factoryCalls == 1 && success.PushCount == 1, "A valid committed ZIP reaches the injected uploader exactly once.");
            Check(completed.State == "completed" && completed.ReceiptID == scenario.Receipt.ReceiptID,
                "The completed result remains bound to the same committed receipt.");
            Check(Hash(scenario.Receipt.OutputPath) == scenario.Receipt.OutputSHA256 &&
                  new FileInfo(scenario.Receipt.OutputPath).Length == scenario.Receipt.OutputBytes,
                "A successful upload does not alter the committed ZIP.");

            await RejectBeforeUploader(scenario, scenario.Request with {
                ProjectSessionID = Guid.NewGuid().ToString()
            }, "A receipt from another project session is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = RefreshReceipt(scenario.Receipt with { PlanPath = Path.Combine(root, "other-plan.h5") })
            }, "A receipt whose selected Plan path changed is rejected against the captured Plan path.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = RefreshReceipt(scenario.Receipt with { ProjectPath = Path.Combine(root, "other-project.ras") })
            }, "A receipt whose source project changed is rejected against the captured project path.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = RefreshReceipt(scenario.Receipt with { SourceRevision = "new-source-revision" })
            }, "A receipt whose source revision changed is rejected against the captured revision.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                CoreLayerContext = scenario.Context with { IdentityToken = "stale-core-token" }
            }, "A stale external core-layer identity token is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Owner = "  "
            }, "A missing application owner identity is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = scenario.Receipt with { OutputBytes = scenario.Receipt.OutputBytes + 1 }
            }, "A receipt with a changed ZIP length is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = scenario.Receipt with { OutputSHA256 = new string('0', 64) }
            }, "A receipt with a changed ZIP hash is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                Receipt = scenario.Receipt with { ReceiptID = "forged-receipt" }, ReceiptID = "forged-receipt"
            }, "A receipt with a forged commit identifier is rejected.");
            await RejectBeforeUploader(scenario, scenario.Request with {
                ReceiptID = "stale-request-receipt"
            }, "The upload request must retain the receipt ID captured from the export stage.");

            File.AppendAllText(scenario.Receipt.OutputPath, "external edit");
            string tamperedHash = Hash(scenario.Receipt.OutputPath);
            await RejectBeforeUploader(scenario, scenario.Request,
                "A ZIP edited after export is rejected before uploader construction.");
            Check(File.Exists(scenario.Receipt.OutputPath) && Hash(scenario.Receipt.OutputPath) == tamperedHash,
                "Rejecting a changed ZIP preserves the caller's current file bytes.");
            File.WriteAllBytes(scenario.Receipt.OutputPath, scenario.OriginalBytes);

            FakeUploader cancelled = new((_, _, _, reporter) =>
            {
                reporter.RequestCancel();
                throw new OperationCanceledException();
            });
            PlanModelUploadResult cancelledResult = await Execute(scenario.Request, (_, _) => cancelled);
            Check(cancelledResult.State == "cancelled" && cancelled.PushCount == 1,
                "Uploader cancellation is surfaced as a cancelled stage.");
            Check(File.Exists(scenario.Receipt.OutputPath) && Hash(scenario.Receipt.OutputPath) == scenario.Receipt.OutputSHA256,
                "Cancellation preserves the already committed ZIP and its exact receipt hash.");

            string controlRequestID = Guid.NewGuid().ToString("D");
            var controlInput = new CancellationControlInput();
            FakeUploader duplexCancelled = new(async (_, _, _, uploadReporter) =>
            {
                controlInput.SendCancel(controlRequestID);
                await WaitForCancellation(uploadReporter);
                throw new OperationCanceledException();
            });
            PlanModelUploadResult duplexCancelledResult = await ExecuteWithControls(scenario.Request,
                (_, _) => duplexCancelled, controlRequestID, controlInput);
            Check(duplexCancelledResult.State == "cancelled" && duplexCancelled.PushCount == 1,
                "A live duplex cancel reaches the active uploader and returns a cancelled upload stage.");
            Check(File.Exists(scenario.Receipt.OutputPath) && Hash(scenario.Receipt.OutputPath) == scenario.Receipt.OutputSHA256,
                "A live duplex cancellation preserves the committed ZIP and its exact receipt hash.");

            FakeUploader timeout = new((_, _, _, _) => throw new OperationCanceledException("offline fake upload timeout"));
            bool timeoutReportedAsFailure = false;
            try
            {
                _ = await Execute(scenario.Request, (_, _) => timeout);
            }
            catch (InvalidOperationException error) when
                (error.Message.Contains("offline fake upload timeout", StringComparison.Ordinal))
            {
                timeoutReportedAsFailure = true;
            }
            Check(timeoutReportedAsFailure,
                "An uploader OperationCanceledException without an explicit cancellation request remains a failure, such as a timeout.");
            Check(File.Exists(scenario.Receipt.OutputPath) && Hash(scenario.Receipt.OutputPath) == scenario.Receipt.OutputSHA256,
                "An uploader timeout preserves the committed ZIP and its exact receipt hash.");

            FakeUploader failed = new((_, _, _, _) => throw new IOException(
                "offline fake upload failed offline-access-key offline-secret-key"));
            try
            {
                _ = await Execute(scenario.Request, (_, _) => failed);
                throw new InvalidOperationException("A fake uploader failure must be reported.");
            }
            catch (InvalidOperationException error) when (error.Message.Contains("offline fake upload failed", StringComparison.Ordinal))
            {
                Check(!error.Message.Contains("offline-access-key", StringComparison.Ordinal) &&
                      !error.Message.Contains("offline-secret-key", StringComparison.Ordinal),
                    "Credential strings are redacted from upload failures.");
            }
            Check(File.Exists(scenario.Receipt.OutputPath) && Hash(scenario.Receipt.OutputPath) == scenario.Receipt.OutputSHA256,
                "A failed upload preserves the committed ZIP for retry.");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task RejectBeforeUploader(Scenario scenario, PlanModelUploadRequest request, string message)
    {
        int factoryCalls = 0;
        try
        {
            _ = await Execute(request, (_, _) =>
            {
                factoryCalls++;
                return new FakeUploader((_, _, _, _) => Task.CompletedTask);
            });
            throw new InvalidOperationException(message + " The upload unexpectedly proceeded.");
        }
        catch (ArgumentException) { }
        catch (InvalidDataException) { }
        catch (FileNotFoundException) { }
        Check(factoryCalls == 0, message + " It must be rejected before any uploader is created.");
    }

    private static Task<PlanModelUploadResult> Execute(PlanModelUploadRequest request,
        Func<string, string, IPlanModelUploader> createUploader)
    {
        var controls = new BackendDuplexControlReader(Guid.NewGuid().ToString("N"), new StringReader(string.Empty));
        return ExecuteAndDispose(request, createUploader, controls);
    }

    private static Task<PlanModelUploadResult> ExecuteWithControls(PlanModelUploadRequest request,
        Func<string, string, IPlanModelUploader> createUploader, string requestID, TextReader input)
    {
        var controls = new BackendDuplexControlReader(requestID, input);
        return ExecuteAndDispose(request, createUploader, controls);
    }

    private static async Task<PlanModelUploadResult> ExecuteAndDispose(PlanModelUploadRequest request,
        Func<string, string, IPlanModelUploader> createUploader, BackendDuplexControlReader controls)
    {
        await using (controls)
            return await PlanModelUploadService.ExecuteDuplexAsync(request, null, controls, createUploader)
                .ConfigureAwait(false);
    }

    private static Scenario CreateScenario(string root)
    {
        string zipPath = Path.Combine(root, "committed.zip");
        byte[] content = Encoding.UTF8.GetBytes("PK\u0003\u0004 offline committed ZIP fixture\n");
        File.WriteAllBytes(zipPath, content);
        string sessionID = Guid.NewGuid().ToString();
        string projectPath = Path.Combine(root, "source.ras");
        string planPath = Path.Combine(root, "plans", "selected.h5");
        string sourceRevision = "source-revision-001";
        string hash = Hash(zipPath);
        long length = new FileInfo(zipPath).Length;
        var context = new CoreLayerRequestContext(sessionID, projectPath, "project-revision-001", [], "core-token-001");
        var receipt = new PlanExportResult(zipPath, true, "source.ras", 4, projectPath, planPath,
            sessionID, sourceRevision, context.IdentityToken, hash, length, "pending");
        receipt = RefreshReceipt(receipt);
        var request = new PlanModelUploadRequest(receipt, sessionID, "offline-model-42", "offline-owner",
            "offline-access-key", "offline-secret-key", projectPath, planPath, sourceRevision,
            receipt.ReceiptID, context);
        return new(receipt, request, context, content);
    }

    private static PlanExportResult RefreshReceipt(PlanExportResult receipt) => receipt with {
        ReceiptID = PlanExportService.CreateReceiptID(receipt.OutputPath, receipt.ProjectPath, receipt.PlanPath,
            receipt.ProjectSessionID, receipt.SourceRevision, receipt.CoreLayerIdentityToken,
            receipt.OutputSHA256, receipt.OutputBytes)
    };

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task WaitForCancellation(ProgressReporter reporter)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!reporter.CancelRequested)
            await Task.Delay(1, timeout.Token).ConfigureAwait(false);
    }

    private sealed record Scenario(PlanExportResult Receipt, PlanModelUploadRequest Request,
        CoreLayerRequestContext Context, byte[] OriginalBytes);

    private sealed class FakeUploader(Func<string, string, string, ProgressReporter, Task> push) : IPlanModelUploader
    {
        internal int PushCount { get; private set; }
        public Task PushAsync(string modelID, string zipPath, string owner, ProgressReporter reporter)
        {
            PushCount++;
            return push(modelID, zipPath, owner, reporter);
        }
        public void Dispose() { }
    }

    private sealed class CancellationControlInput : TextReader
    {
        private readonly TaskCompletionSource<string?> line = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int lineRead;

        public void SendCancel(string requestID) => line.TrySetResult(JsonSerializer.Serialize(new
        {
            id = requestID,
            controlSequence = 1,
            control = new { type = "cancel" }
        }));

        public override ValueTask<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            if (Interlocked.Exchange(ref lineRead, 1) != 0)
                return ValueTask.FromResult<string?>(null);
            return new(line.Task.WaitAsync(cancellationToken));
        }
    }
}
