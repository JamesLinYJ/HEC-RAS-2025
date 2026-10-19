using System.Security.Cryptography;
using System.Text;
using Ras.Backend;

internal static class InitialConditionsTransactionChecks
{
    internal static async Task Run()
    {
        await InterruptedPublishRecoversAndPreservesReceipt();
        await PublishedPairWithoutCommittedJournalRecovers();
        await FailedPublishRollsBackAndCanRetry();
        await ExternalRevisionConflictIsNeverOverwritten();
        await ChangedConsumedResultPreventsOrRollsBackPublication();
        await ReusedOperationCannotChangeItsPersistedPayload();
        await SameOperationConcurrentRetryIsIdempotent();
        Console.WriteLine("Initial-condition paired-file transactions recover safely and preserve operation identity.");
    }

    private static Task PublishedPairWithoutCommittedJournalRecovers()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "published-pair");
        InitialConditionsTransactionOutcome interrupted = InitialConditionsTransaction.Commit(
            files.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterProjectPublish
                ? InitialConditionsTransactionFailpointAction.Interrupt
                : InitialConditionsTransactionFailpointAction.Continue);

        Check(interrupted.State == "prepared", "Both published files remain prepared until the committed journal is durable.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.NewProject), "The complete new project XML is independently visible.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "The complete staged model is independently visible.");
        Check(InitialConditionsTransaction.ReadStatus(files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest).State == "prepared",
            "A lost receipt does not make the read-only status path mutate a prepared journal.");

        InitialConditionsTransactionOutcome recovered = InitialConditionsTransaction.Recover(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(recovered.State == "committed" && recovered.ProjectRevision == Hash(files.NewProject) &&
              recovered.ModelRevision == Hash(files.NewModel), "Recovery records the already-published exact byte pair.");
        return Task.CompletedTask;
    }

    private static Task InterruptedPublishRecoversAndPreservesReceipt()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "interrupt");
        InitialConditionsTransactionOutcome interrupted = InitialConditionsTransaction.Commit(
            files.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterModelPublish
                ? InitialConditionsTransactionFailpointAction.Interrupt
                : InitialConditionsTransactionFailpointAction.Continue);

        Check(interrupted.State == "prepared", "An interrupted one-file publish remains recoverable.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.OldProject), "The project has not been published with only the model file.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "The first published model file is visible after interruption.");
        InitialConditionsTransactionStatus beforeRecovery = InitialConditionsTransaction.ReadStatus(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(beforeRecovery.State == "prepared" && beforeRecovery.Receipt is null, "Status reports prepared without mutating files or claiming a receipt.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.OldProject), "ReadStatus is read-only during partial publication.");

        InitialConditionsTransactionOutcome recovered = InitialConditionsTransaction.Recover(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(recovered.State == "committed" && !recovered.AlreadyCommitted, "Recovery completes the same prepared operation.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.NewProject), "Independent project reread sees exact UTF-8 XML bytes.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "Independent model reread sees the staged source bytes.");
        Check(recovered.ProjectXml == files.NewProjectXml && recovered.ConnectionName == files.ConnectionName,
            "The committed receipt retains the exact project draft and source connection name.");

        InitialConditionsTransactionStatus committed = InitialConditionsTransaction.ReadStatus(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(committed.State == "committed" && committed.Receipt is { AlreadyCommitted: true },
            "A lost-response retry can recover the durable committed receipt.");
        InitialConditionsTransactionOutcome receipt = committed.Receipt
            ?? throw new InvalidOperationException("The committed status did not include its operation receipt.");
        Check(receipt.ProjectRevision == Hash(files.NewProject) && receipt.ModelRevision == Hash(files.NewModel),
            "The receipt revisions match the independently read committed pair.");
        return Task.CompletedTask;
    }

    private static Task FailedPublishRollsBackAndCanRetry()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "rollback");
        InitialConditionsTransactionOutcome failed = InitialConditionsTransaction.Commit(
            files.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterModelPublish
                ? InitialConditionsTransactionFailpointAction.Fail
                : InitialConditionsTransactionFailpointAction.Continue);

        Check(failed.State == "rolledBack" && !string.IsNullOrWhiteSpace(failed.ErrorMessage), "A failed second publish reports rollback, not success.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.OldProject), "Failed paired commit preserves the original project bytes.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.OldModel), "Failed paired commit restores the original model bytes.");
        InitialConditionsTransactionStatus rolledBack = InitialConditionsTransaction.ReadStatus(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(rolledBack.State == "rolledBack", "The rollback is durably journaled.");

        InitialConditionsTransactionOutcome retry = InitialConditionsTransaction.Recover(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(retry.State == "committed", "Retry reuses the prepared operation without re-running source preparation.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.NewProject), "Retry publishes the same exact project draft.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "Retry publishes the same exact staged model.");
        return Task.CompletedTask;
    }

    private static Task ExternalRevisionConflictIsNeverOverwritten()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "external-edit");
        byte[] externalProject = Encoding.UTF8.GetBytes("<Project><!-- newer independent edit --></Project>");
        File.WriteAllBytes(files.ProjectPath, externalProject);

        InitialConditionsTransactionOutcome conflict = InitialConditionsTransaction.Commit(files.Request);
        Check(conflict.State == "conflict", "A changed project revision prevents initial publication.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(externalProject), "The newer project edit remains byte-for-byte intact.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.OldModel), "A conflict does not publish the staged model.");
        InitialConditionsTransactionStatus status = InitialConditionsTransaction.ReadStatus(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(status.State == "conflict", "The conflict is available to a lost-response status query.");

        var partial = FileSet.Create(directory.FullName, "recovery-conflict");
        _ = InitialConditionsTransaction.Commit(partial.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterModelPublish
                ? InitialConditionsTransactionFailpointAction.Interrupt
                : InitialConditionsTransactionFailpointAction.Continue);
        byte[] laterProject = Encoding.UTF8.GetBytes("<Project><!-- edited after the partial publish --></Project>");
        File.WriteAllBytes(partial.ProjectPath, laterProject);
        Check(File.ReadAllBytes(partial.ModelPath).SequenceEqual(partial.NewModel), "The interrupted operation published exactly its staged model before the external project edit.");
        InitialConditionsTransactionStatus pendingStatus = InitialConditionsTransaction.ReadStatus(
            partial.ProjectPath, partial.Request.OperationID, partial.Request.RequestDigest);
        Check(pendingStatus.State == "prepared" && !string.IsNullOrWhiteSpace(pendingStatus.ErrorMessage),
            "ReadStatus keeps a prepared operation recoverable and reports the external project revision without finalizing it.");
        Check(File.ReadAllBytes(partial.ProjectPath).SequenceEqual(laterProject) &&
              File.ReadAllBytes(partial.ModelPath).SequenceEqual(partial.NewModel),
            "ReadStatus leaves both the external project edit and the transaction-owned partial model output untouched.");
        InitialConditionsTransactionOutcome recoveryConflict = InitialConditionsTransaction.Recover(
            partial.ProjectPath, partial.Request.OperationID, partial.Request.RequestDigest);
        Check(recoveryConflict.State == "conflict", "Recovery stops when one target no longer has a journaled revision.");
        Check(File.ReadAllBytes(partial.ProjectPath).SequenceEqual(laterProject), "Recovery never overwrites a newer project edit.");
        Check(File.ReadAllBytes(partial.ModelPath).SequenceEqual(partial.OldModel), "Recovery rolls back its own known partial output while preserving the external project edit.");
        Check(InitialConditionsTransaction.ReadStatus(partial.ProjectPath, partial.Request.OperationID, partial.Request.RequestDigest).State == "conflict",
            "Recovery durably journals the conflict after rolling back only the transaction-owned model output.");
        return Task.CompletedTask;
    }

    private static Task ChangedConsumedResultPreventsOrRollsBackPublication()
    {
        using var directory = new TemporaryDirectory();
        var before = FileSet.Create(directory.FullName, "changed-result-before");
        byte[] newerResult = [0x89, 0x48, 0x44, 0x46, 0x99];
        File.WriteAllBytes(before.DependencyPath, newerResult);
        InitialConditionsTransactionOutcome rejected = InitialConditionsTransaction.Commit(before.Request);
        Check(rejected.State == "conflict", "A changed result HDF prevents the paired commit from beginning.");
        Check(File.ReadAllBytes(before.ProjectPath).SequenceEqual(before.OldProject) &&
              File.ReadAllBytes(before.ModelPath).SequenceEqual(before.OldModel), "A stale consumed result leaves both source targets unchanged.");

        var during = FileSet.Create(directory.FullName, "changed-result-during");
        InitialConditionsTransactionOutcome rolledBack = InitialConditionsTransaction.Commit(
            during.Request,
            point =>
            {
                if (point == InitialConditionsTransactionFailpoint.AfterModelPublish)
                {
                    File.WriteAllBytes(during.DependencyPath, newerResult);
                }
                return InitialConditionsTransactionFailpointAction.Continue;
            });
        Check(rolledBack.State == "rolledBack", "A consumed result changed during publication, so exact new targets are rolled back.");
        Check(File.ReadAllBytes(during.ProjectPath).SequenceEqual(during.OldProject) &&
              File.ReadAllBytes(during.ModelPath).SequenceEqual(during.OldModel), "Result-revision failure restores both original targets.");
        Check(File.ReadAllBytes(during.DependencyPath).SequenceEqual(newerResult), "The independent result edit is never touched.");
        Check(InitialConditionsTransaction.ReadStatus(during.ProjectPath, during.Request.OperationID, during.Request.RequestDigest).State == "conflict",
            "A rolled-back operation cannot be retried after its consumed result changed.");

        var interrupted = FileSet.Create(directory.FullName, "changed-result-after-interrupt");
        _ = InitialConditionsTransaction.Commit(interrupted.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterModelPublish
                ? InitialConditionsTransactionFailpointAction.Interrupt
                : InitialConditionsTransactionFailpointAction.Continue);
        File.WriteAllBytes(interrupted.DependencyPath, newerResult);
        Check(File.ReadAllBytes(interrupted.ModelPath).SequenceEqual(interrupted.NewModel),
            "The interrupted fixture has one exact transaction output to recover.");
        InitialConditionsTransactionStatus pendingStatus = InitialConditionsTransaction.ReadStatus(
            interrupted.ProjectPath, interrupted.Request.OperationID, interrupted.Request.RequestDigest);
        Check(pendingStatus.State == "prepared" && !string.IsNullOrWhiteSpace(pendingStatus.ErrorMessage),
            "ReadStatus keeps the stale-dependency operation recoverable and reports the issue without finalizing it.");
        Check(File.ReadAllBytes(interrupted.ProjectPath).SequenceEqual(interrupted.OldProject) &&
              File.ReadAllBytes(interrupted.ModelPath).SequenceEqual(interrupted.NewModel),
            "ReadStatus does not alter either target before recovery is requested.");
        InitialConditionsTransactionOutcome staleRecovery = InitialConditionsTransaction.Recover(
            interrupted.ProjectPath, interrupted.Request.OperationID, interrupted.Request.RequestDigest);
        Check(staleRecovery.State == "rolledBack", "Recovery restores the still-owned model after the consumed result changes and journals rollback.");
        Check(File.ReadAllBytes(interrupted.ProjectPath).SequenceEqual(interrupted.OldProject) &&
              File.ReadAllBytes(interrupted.ModelPath).SequenceEqual(interrupted.OldModel),
            "Recovery safely rolls back known partial outputs after the consumed result changes.");
        Check(File.ReadAllBytes(interrupted.DependencyPath).SequenceEqual(newerResult), "Stale recovery leaves the edited result file intact.");
        return Task.CompletedTask;
    }

    private static async Task SameOperationConcurrentRetryIsIdempotent()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "concurrent");
        InitialConditionsTransactionOutcome[] outcomes = await Task.WhenAll(
            Task.Run(() => InitialConditionsTransaction.Commit(files.Request)),
            Task.Run(() => InitialConditionsTransaction.Commit(files.Request)));

        Check(outcomes.All(outcome => outcome.State == "committed"), "Concurrent exact retries converge on one committed operation.");
        Check(outcomes.Count(outcome => outcome.AlreadyCommitted) == 1, "Exactly one concurrent caller observes the prior committed receipt.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.NewProject), "Concurrent retry leaves the exact project bytes.");
        Check(File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "Concurrent retry leaves the exact model bytes.");
    }

    private static Task ReusedOperationCannotChangeItsPersistedPayload()
    {
        using var directory = new TemporaryDirectory();
        var files = FileSet.Create(directory.FullName, "request-payload");
        _ = InitialConditionsTransaction.Commit(files.Request,
            point => point == InitialConditionsTransactionFailpoint.AfterModelPublish
                ? InitialConditionsTransactionFailpointAction.Interrupt
                : InitialConditionsTransactionFailpointAction.Continue);

        InitialConditionsTransactionRequest changedRequest = files.Request with
        {
            NewProjectXml = "<Project><Connections><Connection Name=\"Different\" /></Connections></Project>"
        };
        InitialConditionsTransactionOutcome rejected = InitialConditionsTransaction.Commit(changedRequest);
        Check(rejected.State == "conflict", "Reusing an operation ID and digest with different saved XML is rejected.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.OldProject) &&
              File.ReadAllBytes(files.ModelPath).SequenceEqual(files.NewModel), "A mismatched replay does not alter the prepared pair.");

        InitialConditionsTransactionOutcome resumed = InitialConditionsTransaction.Recover(
            files.ProjectPath, files.Request.OperationID, files.Request.RequestDigest);
        Check(resumed.State == "committed" && resumed.ProjectXml == files.NewProjectXml,
            "The original persisted request remains recoverable after a rejected payload replay.");
        Check(File.ReadAllBytes(files.ProjectPath).SequenceEqual(files.NewProject), "Recovery publishes the original operation XML.");
        return Task.CompletedTask;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record FileSet(
        string ProjectPath,
        string ModelPath,
        string StagedModelPath,
        string DependencyPath,
        byte[] OldProject,
        byte[] OldModel,
        byte[] OldDependency,
        byte[] NewProject,
        byte[] NewModel,
        string NewProjectXml,
        string ConnectionName,
        InitialConditionsTransactionRequest Request)
    {
        internal static FileSet Create(string root, string operationSuffix)
        {
            string projectPath = Path.Combine(root, operationSuffix + ".ras");
            string modelPath = Path.Combine(root, operationSuffix + ".hdf");
            string stagedModelPath = Path.Combine(root, operationSuffix + ".hdf.staged");
            string dependencyPath = Path.Combine(root, operationSuffix + ".result.hdf");
            byte[] oldProject = Encoding.UTF8.GetBytes("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Project><Comment>保留</Comment></Project>\n");
            byte[] oldModel = [0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a, 0x10, 0x20, 0x30];
            byte[] oldDependency = [0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a, 0x70, 0x80, 0x90];
            byte[] newModel = [0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a, 0x40, 0x50, 0x60];
            string projectXml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Project><!-- keep --><Comment>保留</Comment><Connections><Connection Name=\"Stage\" /></Connections></Project>\n";
            byte[] newProject = new UTF8Encoding(false, true).GetBytes(projectXml);
            string connectionName = "Stage";
            File.WriteAllBytes(projectPath, oldProject);
            File.WriteAllBytes(modelPath, oldModel);
            File.WriteAllBytes(stagedModelPath, newModel);
            File.WriteAllBytes(dependencyPath, oldDependency);
            string operationID = Guid.NewGuid().ToString("N");
            string digest = Hash(Encoding.UTF8.GetBytes("request:" + operationSuffix));
            var request = new InitialConditionsTransactionRequest(
                projectPath,
                modelPath,
                stagedModelPath,
                operationID,
                digest,
                Hash(oldProject),
                Hash(oldModel),
                projectXml,
                connectionName,
                dependencyPath,
                Hash(oldDependency));
            return new(projectPath, modelPath, stagedModelPath, dependencyPath, oldProject, oldModel, oldDependency,
                newProject, newModel, projectXml, connectionName, request);
        }
    }
}
