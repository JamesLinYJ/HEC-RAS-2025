using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Ras.Backend;

/// <summary>
/// Exercises the actual Geometry-owned CPU renderers against the generated
/// source mesh fixture used by GeometryMeshChecks. The check deliberately
/// calls the same adapter operation wired to geometry.mesh.plotRender.
/// </summary>
internal static class GeometryMeshPlotRenderingChecks
{
    private const int PixelWidth = 192;
    private const int PixelHeight = 192;

    internal static async Task RunAsync(GeometryMeshModelRequest model, GeometryMeshSnapshot mesh,
        string topologyDraftState, string staleTopologyDraftState)
    {
        string projectPath = model.ProjectPath
            ?? throw new InvalidOperationException("The Geometry plot fixture must retain its project path.");
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        FileSnapshot hdfBefore = Snapshot(model.AssetPath);
        FileSnapshot projectBefore = Snapshot(projectPath);
        FileSnapshot visualizationBefore = Snapshot(visualizationPath);

        string meshDraftSHA256 = Digest(mesh.DraftState);
        string topologyDraftSHA256 = Digest(topologyDraftState);
        string mapID = Guid.NewGuid().ToString("D");
        var commonRequest = new GeometryMeshPlotRenderRequest(
            model,
            SourceIdentity: string.Join("|", Path.GetFullPath(model.AssetPath), model.Kind,
                mesh.Revision, meshDraftSHA256, topologyDraftSHA256),
            MapID: mapID,
            MapContextToken: "geometry-plot-test-context-" + mapID,
            GeometryNodeIdentity: Path.GetFullPath(model.AssetPath),
            ProjectRevision: Digest(File.ReadAllBytes(projectPath)),
            VisualizationRevision: Digest(visualizationBefore.Bytes),
            SourceRevision: mesh.Revision,
            MeshDraftState: mesh.DraftState,
            MeshDraftSHA256: meshDraftSHA256,
            TopologyDraftState: topologyDraftState,
            TopologyDraftSHA256: topologyDraftSHA256,
            OwnerMode: "parentDraft",
            Viewport: new GeometryMeshPlotViewport(-1, -1, 21, 21),
            PixelWidth: PixelWidth,
            PixelHeight: PixelHeight,
            RenderScale: 1,
            PixelSamplingScale: 1,
            StyleScope: "global",
            StyleRevision: "",
            GlobalStyleRevision: 7,
            StylePacketSHA256: "",
            StyleIdentity: "",
            Styles: new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal),
            RendererFamily: "Mesh",
            Options: new Dictionary<string, string>(StringComparer.Ordinal));

        var meshStyle = new MapVectorPlotStyleValues("#805020D0", 1.5, "#80401080", 6,
            "#00000000", 0, 0);
        var meshRequest = WithStylePacket(commonRequest with
        {
            RendererFamily = "Mesh",
            Options = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["LabelCells"] = "true",
                ["LabelFaces"] = "true",
                ["LabelFacePoints"] = "true",
                ["RenderPerimeter"] = "true",
                ["RenderQuality"] = "CellIndex"
            }
        }, "localVis", "fixture-vis-mesh", 7,
            new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal)
            {
                ["Mesh_Line_Symbology"] = meshStyle
            });

        GeometryMeshPlotRenderResponse meshPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            meshRequest);
        CheckActualRender(meshPlot, meshRequest, "Mesh");
        RequireOptions(meshPlot, ["LabelCells", "LabelFaces", "LabelFacePoints", "RenderPerimeter", "RenderQuality"]);
        Check(meshPlot.Labels.Any(label => label.Text.StartsWith("C[", StringComparison.Ordinal))
            && meshPlot.Labels.Any(label => label.Text.StartsWith("F[", StringComparison.Ordinal))
            && meshPlot.Labels.Any(label => label.Text.StartsWith("FP[", StringComparison.Ordinal))
            && meshPlot.Options.Single(option => option.PropertyName == "RenderQuality") is
                { Kind: "enum", Value: "CellIndex", HasDrawingImplementation: true }
            && meshPlot.Options.Single(option => option.PropertyName == "RenderQuality").EnumValues
                .Any(choice => choice.Value == "Composite" && choice.Label == "Composite"),
            "The retained MeshRenderLayer emits source cell/face labels and authoritative enum metadata.");
        Check(meshPlot.AppliedStyles.Count == 1 && meshPlot.AppliedStyles["Mesh_Line_Symbology"] == meshStyle,
            "MeshRenderLayer accepts the exact local Geometry style packet.");

        GeometryMeshPlotRenderRequest scaleBaseRequest = WithStylePacket(meshRequest with
        {
            Options = new Dictionary<string, string>(StringComparer.Ordinal) { ["LabelCells"] = "true" },
            RenderScale = 1
        }, "localVis", "fixture-vis-mesh", 7,
            new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal)
            {
                ["Mesh_Line_Symbology"] = meshStyle
            });
        GeometryMeshPlotRenderRequest scaledMeshRequest = WithStylePacket(scaleBaseRequest with { RenderScale = 3 },
            "localVis", "fixture-vis-mesh", 7, scaleBaseRequest.Styles);
        GeometryMeshPlotRenderRequest reducedSamplingMeshRequest = WithStylePacket(scaleBaseRequest with
        {
            PixelWidth = PixelWidth / 2,
            PixelHeight = PixelHeight / 2,
            RenderScale = 2,
            PixelSamplingScale = 0.5
        }, "localVis", "fixture-vis-mesh", 7, scaleBaseRequest.Styles);
        double previousScale = Geospatial.Rendering.Systems.Vector.VectorManagerOptions.RenderScaling;
        GeometryMeshPlotRenderResponse scaleBase;
        GeometryMeshPlotRenderResponse scaleUp;
        GeometryMeshPlotRenderResponse reducedSampling;
        try
        {
            Geospatial.Rendering.Systems.Vector.VectorManagerOptions.RenderScaling = 0.75;
            scaleBase = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(scaleBaseRequest);
            scaleUp = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(scaledMeshRequest);
            reducedSampling = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(reducedSamplingMeshRequest);
            Check(Geospatial.Rendering.Systems.Vector.VectorManagerOptions.RenderScaling == 0.75,
                "Each Geometry source render restores the backend's prior process RenderScaling value.");
        }
        finally
        {
            Geospatial.Rendering.Systems.Vector.VectorManagerOptions.RenderScaling = previousScale;
        }
        byte[] baseMeshPixels = Convert.FromBase64String(scaleBase.PixelsRGBA);
        byte[] scaledMeshPixels = Convert.FromBase64String(scaleUp.PixelsRGBA);
        int differingMeshPixelCount = 0;
        for (int index = 0; index < Math.Min(baseMeshPixels.Length, scaledMeshPixels.Length); index += 4)
        {
            if (baseMeshPixels[index] != scaledMeshPixels[index]
                || baseMeshPixels[index + 1] != scaledMeshPixels[index + 1]
                || baseMeshPixels[index + 2] != scaledMeshPixels[index + 2]
                || baseMeshPixels[index + 3] != scaledMeshPixels[index + 3])
                differingMeshPixelCount++;
        }
        int baseMeshPenPixels = CountPremultipliedColorPixels(scaleBase.PixelsRGBA, meshStyle.PenColor);
        int scaledMeshPenPixels = CountPremultipliedColorPixels(scaleUp.PixelsRGBA, meshStyle.PenColor);
        Check(scaleUp.RenderScale == 3 && scaleBase.RenderScale == 1
            && scaleUp.PixelSamplingScale == 1 && scaleBase.PixelSamplingScale == 1
            && scaleUp.SourceRenderScale == 3 && scaleBase.SourceRenderScale == 1
            && scaleUp.Viewport == scaleBase.Viewport
            && scaleUp.RasterExtent == scaleBase.RasterExtent
            && scaleUp.PixelWidth == scaleBase.PixelWidth && scaleUp.PixelHeight == scaleBase.PixelHeight,
            $"Mesh scale requests retain their distinct UI/source scales and fixed viewport: base={scaleBase.RenderScale}/{scaleBase.PixelSamplingScale}/{scaleBase.SourceRenderScale}, scaled={scaleUp.RenderScale}/{scaleUp.PixelSamplingScale}/{scaleUp.SourceRenderScale}, basePx={scaleBase.PixelWidth}x{scaleBase.PixelHeight}, scaledPx={scaleUp.PixelWidth}x{scaleUp.PixelHeight}.");
        Check(!baseMeshPixels.SequenceEqual(scaledMeshPixels) && baseMeshPenPixels != scaledMeshPenPixels,
            $"Source RenderScaling must change actual Mesh face-edge RGBA pen pixels at fixed viewport/sampling; changedPixels={differingMeshPixelCount}, basePenPixels={baseMeshPenPixels}, scale3PenPixels={scaledMeshPenPixels}, baseSplat={scaleBase.PaintedPixels}, scale3Splat={scaleUp.PaintedPixels}, sourceScales={scaleBase.SourceRenderScale}/{scaleUp.SourceRenderScale}.");
        CheckActualRender(reducedSampling, reducedSamplingMeshRequest, "Mesh reduced sampling");
        int reducedSamplingPenPixels = CountPremultipliedColorPixels(reducedSampling.PixelsRGBA, meshStyle.PenColor);
        double screenPenFootprintRatio = reducedSamplingPenPixels
            / (reducedSamplingMeshRequest.PixelSamplingScale * reducedSamplingMeshRequest.PixelSamplingScale)
            / baseMeshPenPixels;
        Check(reducedSampling.SourceRenderScale == 1
            && reducedSampling.RenderScale == 2 && reducedSampling.PixelSamplingScale == 0.5
            && reducedSampling.PixelWidth == PixelWidth / 2 && reducedSampling.PixelHeight == PixelHeight / 2
            && reducedSampling.Viewport == scaleBase.Viewport
            && ViewportMatches(reducedSampling.RasterExtent, scaleBase.RasterExtent)
            && baseMeshPenPixels > 0 && reducedSamplingPenPixels > 0
            && screenPenFootprintRatio is > 1.2 and < 3.2,
            "A 2x on-screen Mesh pen rendered at half sampling keeps source width at one raster pixel and approximately doubles its reconstructed screen footprint.");
        Check(HasPremultipliedColor(scaleBase.PixelsRGBA, meshStyle.PenColor),
            "MeshRenderLayer emits the custom source ARGB color with correct alpha premultiplication.");

        var widePenStyle = meshStyle with { PenWidth = 3.5 };
        GeometryMeshPlotRenderRequest widePenRequest = WithStylePacket(scaleBaseRequest, "localVis",
            "fixture-vis-mesh", 7,
            new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal)
            {
                ["Mesh_Line_Symbology"] = widePenStyle
            });
        GeometryMeshPlotRenderResponse widePenPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            widePenRequest);
        CheckActualRender(widePenPlot, widePenRequest, "Mesh wider pen");
        int widePenPixels = CountPremultipliedColorPixels(widePenPlot.PixelsRGBA, widePenStyle.PenColor);
        Check(widePenPixels > baseMeshPenPixels
            && !Convert.FromBase64String(widePenPlot.PixelsRGBA).SequenceEqual(baseMeshPixels),
            $"The Mesh face-edge CPU path paints a wider source pen at fixed RenderScaling; base={baseMeshPenPixels}, wide={widePenPixels}, widths={meshStyle.PenWidth}/{widePenStyle.PenWidth}.");

        GeometryMeshPlotRenderRequest clippedMeshRequest = WithStylePacket(scaleBaseRequest with
        {
            Viewport = new GeometryMeshPlotViewport(2, 2, 18, 18),
            PixelWidth = PixelWidth / 2,
            PixelHeight = PixelHeight / 2
        }, "localVis", "fixture-vis-mesh", 7, scaleBaseRequest.Styles);
        GeometryMeshPlotRenderResponse clippedMeshPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            clippedMeshRequest);
        CheckActualRender(clippedMeshPlot, clippedMeshRequest, "Mesh clipped viewport");
        Check(CountPremultipliedColorPixels(clippedMeshPlot.PixelsRGBA, meshStyle.PenColor) > 0
            && ViewportMatches(clippedMeshPlot.RasterExtent, clippedMeshRequest.Viewport)
            && clippedMeshPlot.PixelWidth == PixelWidth / 2
            && clippedMeshPlot.PixelHeight == PixelHeight / 2,
            "The thick Mesh edge rasterizer clips the source mesh to the requested smaller viewport and pixel bounds.");

        var transparentPenStyle = meshStyle with { PenColor = "#005020D0" };
        GeometryMeshPlotRenderRequest transparentMeshRequest = WithStylePacket(scaleBaseRequest with
        {
            Options = new Dictionary<string, string>(StringComparer.Ordinal) { ["LabelCells"] = "false" }
        }, "localVis", "fixture-vis-mesh", 7,
            new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal)
            {
                ["Mesh_Line_Symbology"] = transparentPenStyle
            });
        GeometryMeshPlotRenderResponse transparentMeshPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            transparentMeshRequest);
        byte[] transparentMeshPixels = Convert.FromBase64String(transparentMeshPlot.PixelsRGBA);
        Check(transparentMeshPlot.PaintedPixels
            && transparentMeshPixels.Length == PixelWidth * PixelHeight * 4
            && Enumerable.Range(0, PixelWidth * PixelHeight).All(index => transparentMeshPixels[index * 4 + 3] == 0),
            "The source Mesh still reports a valid painted frame when its pen alpha is zero, and RGBA conversion preserves full transparency.");

        var conceptualStyles = new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal)
        {
            ["Arc_Line_Symbology"] = new("#8060A0E0", 2.25, "#8060A0E0", 3, "#00000000", 0, 0),
            ["Node_Symbology"] = new("#FF10C0A0", 1.5, "#FF10C0A0", 9, "#00000000", 0, 0),
            ["Deletable_Node_Symbology"] = new("#FFE03020", 1.25, "#80E03020", 7, "#00000000", 0, 0),
            ["Internal_Point_Symbology"] = new("#FFB030D0", 1, "#FFB030D0", 5, "#00000000", 0, 0)
        };
        GeometryMeshPlotRenderRequest conceptualRequest = WithStylePacket(commonRequest with
        {
            RendererFamily = "ConceptualMesh",
            Options = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["ShowArcIndexing"] = "true",
                ["ShowDirectionArrows"] = "true",
                ["ShowArcVertices"] = "true",
                ["ShowRegionIndexing"] = "true"
            }
        }, "global", "", 7, conceptualStyles);
        GeometryMeshPlotRenderResponse conceptualPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            conceptualRequest);
        CheckActualRender(conceptualPlot, conceptualRequest, "ConceptualMesh");
        RequireOptions(conceptualPlot,
        [
            "ShowArcIndexing", "ShowDirectionArrows", "ShowArcVertices", "ShowRegionIndexing",
            "ShowGlobalSizeFunction", "ShowSizeFunctionEdges", "ShowArcCellSizes",
            "ShowRegionCellSizes", "ShowRegionSizePreviews"
        ]);
        Check(conceptualPlot.Labels.Any(label => label.Text.StartsWith("Arc ", StringComparison.Ordinal))
            && conceptualPlot.Options.Where(option => option.PropertyName is
                    "ShowArcIndexing" or "ShowDirectionArrows" or "ShowArcVertices")
                .All(option => option.HasDrawingImplementation && option.IsEnabled && option.Value == "true"),
            "The retained ConceptualMeshRenderLayer reports and runs its inherited NetworkRenderLayer options.");
        Check(conceptualPlot.AppliedStyles.Count == 4
            && conceptualPlot.AppliedStyles.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .SequenceEqual(conceptualStyles.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            && HasPremultipliedColor(conceptualPlot.PixelsRGBA, conceptualStyles["Arc_Line_Symbology"].PenColor),
            "ConceptualMeshRenderLayer applies exact global Arc, Node, Deletable Node, and Internal Point symbology setters.");
        GeometryMeshPlotRenderRequest reducedSamplingConceptualRequest = WithStylePacket(conceptualRequest with
        {
            PixelWidth = PixelWidth / 2,
            PixelHeight = PixelHeight / 2,
            RenderScale = 2,
            PixelSamplingScale = 0.5
        }, "global", "", 7, conceptualStyles);
        GeometryMeshPlotRenderResponse reducedSamplingConceptual =
            await ModelEditorAdapter.RenderGeometryMeshPlotAsync(reducedSamplingConceptualRequest);
        CheckActualRender(reducedSamplingConceptual, reducedSamplingConceptualRequest,
            "ConceptualMesh reduced sampling");
        int baseNodePixels = CountPremultipliedColorPixels(conceptualPlot.PixelsRGBA,
            conceptualStyles["Node_Symbology"].PenColor);
        int reducedSamplingNodePixels = CountPremultipliedColorPixels(reducedSamplingConceptual.PixelsRGBA,
            conceptualStyles["Node_Symbology"].PenColor);
        double screenNodeMarkerAreaRatio = reducedSamplingNodePixels
            / (reducedSamplingConceptualRequest.PixelSamplingScale
                * reducedSamplingConceptualRequest.PixelSamplingScale)
            / baseNodePixels;
        Check(reducedSamplingConceptual.SourceRenderScale == 1
            && reducedSamplingConceptual.RenderScale == 2
            && reducedSamplingConceptual.PixelSamplingScale == 0.5
            && reducedSamplingConceptual.Viewport == conceptualPlot.Viewport
            && ViewportMatches(reducedSamplingConceptual.RasterExtent, conceptualPlot.RasterExtent)
            && baseNodePixels > 0 && reducedSamplingNodePixels > 0
            && screenNodeMarkerAreaRatio is > 2.5 and < 5.5,
            "A 2x on-screen Conceptual Mesh node marker keeps its source raster diameter while its reconstructed screen area grows approximately 4x.");

        GeometryMeshPlotRenderRequest tinRequest = WithStylePacket(commonRequest with
        {
            RendererFamily = "TopologyTIN",
            Options = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["RenderEdges"] = "true",
                ["RenderPoints"] = "true",
                ["LabelTris"] = "true",
                ["LabelEdges"] = "true"
            }
        }, "sourceDefault", "", 0,
            new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal));
        GeometryMeshPlotRenderResponse tinPlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            tinRequest);
        CheckActualRender(tinPlot, tinRequest, "TopologyTIN");
        RequireOptions(tinPlot, ["RenderEdges", "RenderPoints", "LabelTris", "LabelEdges", "LabelPoints"]);
        GeometryMeshPlotOptionDescriptor pointLabels = tinPlot.Options.Single(option => option.PropertyName == "LabelPoints");
        Check(tinPlot.Labels.Any(label => label.Text.StartsWith("T[", StringComparison.Ordinal))
            && tinPlot.Labels.Any(label => label.Text.Contains("-E[", StringComparison.Ordinal))
            && pointLabels is { HasDrawingImplementation: false, IsEnabled: false }
            && !string.IsNullOrWhiteSpace(pointLabels.ImplementationNote),
            "The source topology TIN emits real triangle labels while its unimplemented point-label option is disabled in metadata.");

        string emptyDraftSHA256 = Digest("");
        GeometryMeshPlotRenderRequest savedSourceRequest = WithStylePacket(commonRequest with
        {
            OwnerMode = "savedSource",
            MeshDraftState = "",
            MeshDraftSHA256 = emptyDraftSHA256,
            TopologyDraftState = null,
            TopologyDraftSHA256 = emptyDraftSHA256,
            RendererFamily = "ConceptualMesh",
            Options = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["ShowArcIndexing"] = "true",
                ["ShowDirectionArrows"] = "true"
            }
        }, "global", "", 7, conceptualStyles);
        GeometryMeshPlotRenderResponse savedSourcePlot = await ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            savedSourceRequest);
        CheckActualRender(savedSourcePlot, savedSourceRequest, "ConceptualMesh saved source");
        Check(savedSourcePlot.OwnerMode == "savedSource"
            && savedSourcePlot.Options.Single(option => option.PropertyName == "ShowArcIndexing").Value == "true"
            && savedSourcePlot.Labels.Any(label => label.Text.StartsWith("Arc ", StringComparison.Ordinal)),
            "Saved-source mode renders the persisted topology without requiring or replaying a parent draft.");
        await ExpectAsync<ArgumentException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            WithStylePacket(commonRequest with
            {
                RendererFamily = "TopologyTIN",
                Options = new Dictionary<string, string>(StringComparer.Ordinal) { ["LabelPoints"] = "true" }
            }, "sourceDefault", "", 0, new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal))));

        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            WithStylePacket(meshRequest with { SourceRevision = Digest("older geometry revision") },
                "localVis", "fixture-vis-mesh", 7, meshRequest.Styles)));
        await ExpectAsync<ArgumentException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            WithStylePacket(commonRequest with
            {
                OwnerMode = "savedSource",
                MeshDraftState = "",
                MeshDraftSHA256 = emptyDraftSHA256,
                TopologyDraftState = topologyDraftState,
                TopologyDraftSHA256 = topologyDraftSHA256,
                RendererFamily = "ConceptualMesh"
            }, "global", "", 7, conceptualStyles)));
        await ExpectAsync<ArgumentException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            WithStylePacket(meshRequest with { MeshDraftSHA256 = Digest("obsolete mesh draft payload") },
                "localVis", "fixture-vis-mesh", 7, meshRequest.Styles)));
        await ExpectAsync<InvalidOperationException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            WithStylePacket(meshRequest with
            {
                TopologyDraftState = staleTopologyDraftState,
                TopologyDraftSHA256 = Digest(staleTopologyDraftState)
            }, "localVis", "fixture-vis-mesh", 7, meshRequest.Styles)));

        await ExpectAsync<ArgumentException>(() => ModelEditorAdapter.RenderGeometryMeshPlotAsync(
            meshRequest with { Styles = new Dictionary<string, MapVectorPlotStyleValues>(StringComparer.Ordinal) }));

        CheckUnchanged(model.AssetPath, hdfBefore, "source Geometry HDF");
        CheckUnchanged(projectPath, projectBefore, "source project");
        CheckUnchanged(visualizationPath, visualizationBefore, "source .vis file");
        Console.WriteLine("Geometry source Mesh, ConceptualMesh/Network and topology TIN CPU plot render, exact styles, alpha, and scale checks passed.");
    }

    private static GeometryMeshPlotRenderRequest WithStylePacket(GeometryMeshPlotRenderRequest request,
        string scope, string styleRevision, ulong globalStyleRevision,
        Dictionary<string, MapVectorPlotStyleValues> styles)
    {
        string packetSHA256 = StylePacketSHA256(styles);
        request = request with
        {
            StyleScope = scope,
            StyleRevision = styleRevision,
            GlobalStyleRevision = globalStyleRevision,
            StylePacketSHA256 = packetSHA256,
            Styles = styles
        };
        string ownerIdentity = string.Join("|", SourceFilePaths.Canonical(request.Model.AssetPath),
            request.Model.Kind, request.Model.ProjectPath ?? "", Digest(request.Model.ProjectXml ?? ""),
            request.SourceRevision, request.MeshDraftSHA256, request.TopologyDraftSHA256);
        string styleIdentity = Digest(string.Join("\n", "geometry-mesh-plot-style-v1",
            request.SourceIdentity, ownerIdentity, request.MapID, request.MapContextToken,
            request.GeometryNodeIdentity, request.ProjectRevision, request.VisualizationRevision,
            request.SourceRevision, request.StyleScope, request.StyleRevision,
            request.GlobalStyleRevision.ToString(CultureInfo.InvariantCulture), packetSHA256));
        return request with { StyleIdentity = styleIdentity };
    }

    private static string StylePacketSHA256(Dictionary<string, MapVectorPlotStyleValues> styles)
    {
        string canonical = string.Join("\n", styles.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair =>
        {
            MapVectorPlotStyleValues value = pair.Value;
            return string.Join("|", pair.Key, value.PenColor.ToUpperInvariant(), DoubleBits(value.PenWidth),
                value.FillColor.ToUpperInvariant(), value.PointSize.ToString(CultureInfo.InvariantCulture),
                value.HaloColor.ToUpperInvariant(), DoubleBits(value.HaloThickness),
                value.TextEmphasis.ToString(CultureInfo.InvariantCulture));
        }));
        return Digest(canonical);
    }

    private static string DoubleBits(double value) =>
        unchecked((ulong)BitConverter.DoubleToInt64Bits(value)).ToString("x", CultureInfo.InvariantCulture);

    private static bool HasPremultipliedColor(string base64, string argbColor)
    {
        byte[] bytes = Convert.FromBase64String(base64);
        uint argb = uint.Parse(argbColor.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        int expectedAlpha = (int)(argb >> 24);
        int expectedRed = (int)((argb >> 16) & 255);
        int expectedGreen = (int)((argb >> 8) & 255);
        int expectedBlue = (int)(argb & 255);
        for (int index = 0; index < bytes.Length; index += 4)
        {
            int alpha = bytes[index + 3];
            if (alpha <= 0 || alpha > expectedAlpha) continue;
            static int Premultiply(int channel, int alpha) => (channel * alpha + 127) / 255;
            if (Math.Abs(bytes[index] - Premultiply(expectedRed, alpha)) <= 1
                && Math.Abs(bytes[index + 1] - Premultiply(expectedGreen, alpha)) <= 1
                && Math.Abs(bytes[index + 2] - Premultiply(expectedBlue, alpha)) <= 1)
                return true;
        }
        return false;
    }

    private static int CountPremultipliedColorPixels(string base64, string argbColor)
    {
        byte[] bytes = Convert.FromBase64String(base64);
        uint argb = uint.Parse(argbColor.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        int expectedAlpha = (int)(argb >> 24);
        int expectedRed = (int)((argb >> 16) & 255);
        int expectedGreen = (int)((argb >> 8) & 255);
        int expectedBlue = (int)(argb & 255);
        static int Premultiply(int channel, int alpha) => (channel * alpha + 127) / 255;
        int count = 0;
        for (int index = 0; index < bytes.Length; index += 4)
        {
            int alpha = bytes[index + 3];
            if (alpha <= 0 || alpha > expectedAlpha) continue;
            if (Math.Abs(bytes[index] - Premultiply(expectedRed, alpha)) <= 1
                && Math.Abs(bytes[index + 1] - Premultiply(expectedGreen, alpha)) <= 1
                && Math.Abs(bytes[index + 2] - Premultiply(expectedBlue, alpha)) <= 1)
                count++;
        }
        return count;
    }

    private static void CheckActualRender(GeometryMeshPlotRenderResponse response,
        GeometryMeshPlotRenderRequest expected, string family)
    {
        byte[] rgba = Convert.FromBase64String(response.PixelsRGBA);
        bool hasVisiblePixel = false;
        int visiblePixelCount = 0;
        for (int index = 3; index < rgba.Length; index += 4)
        {
            if (rgba[index] == 0) continue;
            hasVisiblePixel = true;
            visiblePixelCount++;
        }
        Check(response.Status == "rendered"
            && response.RendererFamily == expected.RendererFamily
            && response.SourceIdentity == expected.SourceIdentity
            && response.MapID == expected.MapID
            && response.MapContextToken == expected.MapContextToken
            && response.GeometryNodeIdentity == expected.GeometryNodeIdentity
            && response.SourceRevision == expected.SourceRevision
            && response.MeshDraftSHA256 == expected.MeshDraftSHA256
            && response.TopologyDraftSHA256 == expected.TopologyDraftSHA256
            && response.OwnerMode == expected.OwnerMode
            && response.Viewport == expected.Viewport
            && response.RenderScale == expected.RenderScale
            && response.PixelSamplingScale == expected.PixelSamplingScale
            && response.SourceRenderScale == expected.RenderScale * expected.PixelSamplingScale
            && response.StylePacketSHA256 == expected.StylePacketSHA256
            && response.StyleIdentity == expected.StyleIdentity
            && response.AppliedStyles is not null
            && response.AppliedStyles.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .SequenceEqual(expected.Styles.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            && ViewportMatches(response.RasterExtent, expected.Viewport)
            && response.PixelWidth == expected.PixelWidth && response.PixelHeight == expected.PixelHeight
            && rgba.Length == expected.PixelWidth * expected.PixelHeight * 4
            && response.PaintedPixels && hasVisiblePixel,
            $"The {family} source renderer returns correlated viewport-sized CPU RGBA pixels; status={response.Status}, painted={response.PaintedPixels}, visible={visiblePixelCount}, labels={response.Labels.Length}, responseSize={response.PixelWidth}x{response.PixelHeight}, expectedSize={expected.PixelWidth}x{expected.PixelHeight}, viewport={response.Viewport.MinX:R},{response.Viewport.MinY:R},{response.Viewport.MaxX:R},{response.Viewport.MaxY:R}, raster={response.RasterExtent.MinX:R},{response.RasterExtent.MinY:R},{response.RasterExtent.MaxX:R},{response.RasterExtent.MaxY:R}, rasterDelta={MaximumViewportDelta(response.RasterExtent, expected.Viewport):R}, scale={response.RenderScale}*{response.PixelSamplingScale}={response.SourceRenderScale}.");
        Check(response.Labels.Length > 0 && response.Labels.All(label =>
                double.IsFinite(label.Point.X) && double.IsFinite(label.Point.Y)
                && label.Polyline.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y))),
            $"The {family} source renderer returns real labels with finite source coordinates.");
    }

    private static void RequireOptions(GeometryMeshPlotRenderResponse response, string[] expected)
    {
        string[] actual = response.Options.Select(option => option.PropertyName).ToArray();
        Check(actual.Length == expected.Length && actual.ToHashSet(StringComparer.Ordinal)
                .SetEquals(expected),
            $"{response.RendererFamily} PlotOptions are returned from the retained source renderer, including inherited options.");
    }

    private static bool ViewportMatches(GeometryMeshPlotViewport actual, GeometryMeshPlotViewport expected) =>
        MaximumViewportDelta(actual, expected) <= Math.Max(1.0, Math.Max(Math.Abs(expected.MinX),
            Math.Max(Math.Abs(expected.MinY), Math.Max(Math.Abs(expected.MaxX), Math.Abs(expected.MaxY))))) * 1e-10;

    private static double MaximumViewportDelta(GeometryMeshPlotViewport actual,
        GeometryMeshPlotViewport expected) => Math.Max(Math.Abs(actual.MinX - expected.MinX),
        Math.Max(Math.Abs(actual.MinY - expected.MinY), Math.Max(Math.Abs(actual.MaxX - expected.MaxX),
            Math.Abs(actual.MaxY - expected.MaxY))));

    private static string Digest(string value) => Digest(Encoding.UTF8.GetBytes(value));

    private static string Digest(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static FileSnapshot Snapshot(string path)
    {
        bool exists = File.Exists(path);
        return exists
            ? new FileSnapshot(true, File.ReadAllBytes(path), File.GetLastWriteTimeUtc(path).Ticks)
            : new FileSnapshot(false, [], 0);
    }

    private static void CheckUnchanged(string path, FileSnapshot before, string description)
    {
        FileSnapshot after = Snapshot(path);
        Check(after.Exists == before.Exists
            && after.Bytes.SequenceEqual(before.Bytes)
            && after.LastWriteTimeTicks == before.LastWriteTimeTicks,
            $"Geometry source rendering and stale-request rejection do not write the {description}.");
    }

    private static async Task ExpectAsync<TException>(Func<Task> operation) where TException : Exception
    {
        try
        {
            await operation();
        }
        catch (TException)
        {
            return;
        }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record FileSnapshot(bool Exists, byte[] Bytes, long LastWriteTimeTicks);
}
