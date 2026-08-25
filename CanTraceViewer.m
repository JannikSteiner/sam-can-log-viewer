%% 
function appOut = CanTraceViewer(trcFile)
%CANTRACEVIEWER PCAN .trc trace viewer for the SAM CAN bus (SAM_CAN.dbc).
%   CANTRACEVIEWER() opens the app with an empty trace; use the "Load .trc
%   file" button to pick a file.
%   CANTRACEVIEWER(trcFile) opens the app and immediately loads trcFile.
%   app = CANTRACEVIEWER(...) also returns the internal handle/data struct
%   (mainly useful for headless testing of the load/decode/update pipeline).

if nargin < 1
    trcFile = '';
end

app = struct();
app.DBC     = parseDBC(fullfile(fileparts(mfilename('fullpath')), 'SAM_CAN.dbc'));
app.Groups  = buildSignalGroups();
app.Trace   = [];
app.Decoded = containers.Map('KeyType','char','ValueType','any');
app.ViewRange = [0 1];  % [tLow tHigh] of the plotted/scrubbable window
app.TabList = gobjects(1,numel(app.Groups));
app.TabHandles = struct('Gauges',{},'Axes',{},'Cursors',{},'Lamps',{},'StatusLabels',{},'Sections',{},'PlotValueLabels',{},'BarCharts',{});

buildUI();

if ~isempty(trcFile) && isfile(trcFile)
    loadFile(trcFile);
end

if nargout > 0
    appOut = app;
end

    % ------------------------------------------------------------------
    function buildUI()
        app.UIFigure = uifigure('Name','SAM CAN Trace Viewer','Position',[80 60 1500 900]);
        app.MainGrid = uigridlayout(app.UIFigure, [3 1], 'RowHeight', {56,'1x',120});

        topGrid = uigridlayout(app.MainGrid, [1 2], 'ColumnWidth', {180,'1x'}, 'Padding',[8 8 8 8]);
        topGrid.Layout.Row = 1;
        app.LoadButton = uibutton(topGrid, 'push', 'Text','Load trace file', ...
            'ButtonPushedFcn', @(~,~) onLoadButton());
        app.FileLabel = uilabel(topGrid, 'Text','No file loaded.', 'FontSize',13);

        app.TabGroup = uitabgroup(app.MainGrid);
        app.TabGroup.Layout.Row = 2;
        app.TabGroup.SelectionChangedFcn = @(~,evt) onTabChanged(evt);

        for gi = 1:numel(app.Groups)
            gcfg = app.Groups(gi);
            tab = uitab(app.TabGroup, 'Title', gcfg.Title);
            app.TabList(gi) = tab;
            app.TabHandles(gi) = buildTabContent(tab, gcfg);
        end

        bottomGrid = uigridlayout(app.MainGrid, [2 1], 'RowHeight', {50,50}, 'RowSpacing',4, 'Padding',[8 8 8 8]);
        bottomGrid.Layout.Row = 3;

        cursorRow = uigridlayout(bottomGrid, [1 2], 'ColumnWidth', {'1x',220}, 'Padding',[0 0 0 0]);
        cursorRow.Layout.Row = 1;
        app.TimelineSlider = uislider(cursorRow, 'Limits',[0 1], 'Value',0, 'Enable','off', ...
            'ValueChangingFcn', @(~,evt) onSlide(evt.Value), ...
            'ValueChangedFcn',  @(~,evt) onSlide(evt.Value));
        app.TimeLabel = uilabel(cursorRow, 'Text','t = -- s', 'HorizontalAlignment','right', 'FontSize',13);

        % Windowed-view range slider: two independent sliders acting as
        % the low/high bound of the plotted/scrubbable time window. The
        % cursor slider above only ever scrubs within [Low, High].
        rangeRow = uigridlayout(bottomGrid, [1 4], 'ColumnWidth', {60,'1x','1x',170}, 'Padding',[0 0 0 0]);
        rangeRow.Layout.Row = 2;
        uilabel(rangeRow, 'Text','View:', 'HorizontalAlignment','right', 'FontSize',13);
        app.RangeLowSlider = uislider(rangeRow, 'Limits',[0 1], 'Value',0, 'Enable','off', ...
            'ValueChangingFcn', @(~,evt) onRangeSlide('low',evt.Value), ...
            'ValueChangedFcn',  @(~,evt) onRangeSlide('low',evt.Value));
        app.RangeHighSlider = uislider(rangeRow, 'Limits',[0 1], 'Value',1, 'Enable','off', ...
            'ValueChangingFcn', @(~,evt) onRangeSlide('high',evt.Value), ...
            'ValueChangedFcn',  @(~,evt) onRangeSlide('high',evt.Value));
        app.RangeLabel = uilabel(rangeRow, 'Text','0.00 - 0.00 s', 'HorizontalAlignment','right', 'FontSize',13);
    end

    % ------------------------------------------------------------------
    function th = buildTabContent(tab, gcfg)
        if ~isempty(gcfg.Sections)
            th = buildDiagnosticsTabContent(tab, gcfg);
            return
        end
        if ~isempty(gcfg.BarCharts)
            th = buildBarChartTabContent(tab, gcfg);
            return
        end

        nGauges = numel(gcfg.Gauges);
        nPlots  = numel(gcfg.Plots);
        nLamps  = numel(gcfg.Lamps);
        nStatus = numel(gcfg.StatusLabels);
        hasStrip = (nLamps + nStatus) > 0;

        rowHeights = {170, '1x'};
        if hasStrip
            rowHeights{end+1} = 56; %#ok<AGROW>
        end
        tg = uigridlayout(tab, [numel(rowHeights) 1], 'RowHeight', rowHeights, 'Padding',[6 6 6 6]);

        gaugeHandles = gobjects(1,nGauges);
        if nGauges > 0
            gg = uigridlayout(tg, [1 nGauges], 'ColumnWidth', repmat({'1x'},1,nGauges));
            gg.Layout.Row = 1;
            for i = 1:nGauges
                gz = gcfg.Gauges(i);
                rng = gz.Range;
                if isempty(rng); rng = [0 100]; end
                gcell = uigridlayout(gg, [2 1], 'RowHeight',{'1x',18}, 'Padding',[2 2 2 2]);
                gcell.Layout.Column = i;
                gau = uigauge(gcell, 'Limits', rng, 'Value', rng(1));
                gau.Layout.Row = 1;
                unitStr = gz.Unit;
                if isempty(unitStr)
                    labelText = gz.Label;
                else
                    labelText = sprintf('%s (%s)', gz.Label, unitStr);
                end
                lbl = uilabel(gcell, 'Text', labelText, 'HorizontalAlignment','center', 'FontSize',10);
                lbl.Layout.Row = 2;
                if isfield(gz,'Uncertain') && gz.Uncertain
                    lbl.FontColor = [0.85 0.55 0.05];
                    lbl.FontAngle = 'italic';
                end
                gaugeHandles(i) = gau;
            end
        end

        [axHandles, cursorHandles, plotValueLabels, plotGrid] = buildPlotAxes(tg, gcfg);
        if isgraphics(plotGrid)
            plotGrid.Layout.Row = 2;
        end

        lampHandles = gobjects(1,nLamps);
        statusHandles = gobjects(1,nStatus);
        if hasStrip
            sg = uigridlayout(tg, [1 nLamps+nStatus]);
            sg.Layout.Row = numel(rowHeights);
            idx = 1;
            for i = 1:nLamps
                cell = uigridlayout(sg, [2 1], 'RowHeight',{'1x',16}, 'Padding',[0 0 0 0]);
                cell.Layout.Column = idx;
                lp = uilamp(cell, 'Color',[0.7 0.7 0.7]);
                lp.Layout.Row = 1;
                uilabel(cell, 'Text', gcfg.Lamps(i).Label, 'FontSize',9, 'HorizontalAlignment','center');
                lampHandles(i) = lp;
                idx = idx + 1;
            end
            for i = 1:nStatus
                cell = uigridlayout(sg, [2 1], 'RowHeight',{'1x',16}, 'Padding',[0 0 0 0]);
                cell.Layout.Column = idx;
                vlbl = uilabel(cell, 'Text','--', 'FontWeight','bold', 'HorizontalAlignment','center');
                vlbl.Layout.Row = 1;
                uilabel(cell, 'Text', gcfg.StatusLabels(i).Label, 'FontSize',9, 'HorizontalAlignment','center');
                statusHandles(i) = vlbl;
                idx = idx + 1;
            end
        end

        th.Gauges = gaugeHandles;
        th.Axes = axHandles;
        th.Cursors = cursorHandles;
        th.Lamps = lampHandles;
        th.StatusLabels = statusHandles;
        th.Sections = struct('Lamps',{},'StatusLabels',{});
        th.PlotValueLabels = plotValueLabels;
        th.BarCharts = gobjects(1,0);
    end

    % ------------------------------------------------------------------
    function [axHandles, cursorHandles, valueLabelHandles, plotGrid] = buildPlotAxes(parent, gcfg)
        % Shared by both tab layouts (normal gauges/plots/strip tabs and
        % the Sections-based diagnostics layout) so a Sections tab like
        % Errors can also carry a real time-series plot alongside its
        % fault panels, using the exact same axes/cursor wiring refreshPlots
        % and updateAtTime already expect.
        %
        % Each plot cell is itself an axes + a narrow value-readout column
        % on the right (one label per line in the plot) -- this is what
        % updateTabValues/updatePlotValues keep in sync with the scrub
        % cursor, i.e. "the numbers next to the plot at the current time".
        nPlots = numel(gcfg.Plots);
        axHandles = gobjects(1,nPlots);
        cursorHandles = gobjects(1,nPlots);
        valueLabelHandles = cell(1,nPlots);
        plotGrid = gobjects(0);
        if nPlots == 0
            return
        end
        ncols = min(2,nPlots);
        nrows = ceil(nPlots/ncols);
        plotGrid = uigridlayout(parent, [nrows ncols]);
        for i = 1:nPlots
            r = ceil(i/ncols);
            c = i - (r-1)*ncols;
            pcfg = gcfg.Plots(i);
            nKeys = max(numel(pcfg.Keys),1);

            cellGrid = uigridlayout(plotGrid, [1 2], 'ColumnWidth', {'1x',140}, ...
                'Padding',[0 0 0 0], 'ColumnSpacing',4);
            cellGrid.Layout.Row = r;
            cellGrid.Layout.Column = c;

            ax = uiaxes(cellGrid);
            ax.Layout.Column = 1;
            title(ax, pcfg.Title);
            xlabel(ax, 'Time (s)');
            hasRightAxis = isfield(pcfg,'RightAxis') && ~isempty(pcfg.RightAxis);
            if hasRightAxis
                yyaxis(ax, 'left');
                ylabel(ax, pcfg.YLabel);
                ax.YLim = pcfg.RightAxis.LeftLimits;
                yyaxis(ax, 'right');
                ylabel(ax, pcfg.RightAxis.Unit);
                ax.YLim = pcfg.RightAxis.LeftLimits * pcfg.RightAxis.Factor;
                yyaxis(ax, 'left');
            else
                ylabel(ax, pcfg.YLabel);
            end
            grid(ax, 'on');
            hold(ax, 'on');
            axHandles(i) = ax;

            valGrid = uigridlayout(cellGrid, [nKeys 1], 'RowHeight', repmat({36},1,nKeys), ...
                'RowSpacing',2, 'Padding',[4 4 4 4]);
            valGrid.Layout.Column = 2;
            vlabs = gobjects(1,nKeys);
            for ki = 1:nKeys
                vlabs(ki) = uilabel(valGrid, 'Text','--', 'FontSize',10.5, ...
                    'FontWeight','bold', 'WordWrap','on');
                vlabs(ki).Layout.Row = ki;
            end
            valueLabelHandles{i} = vlabs;
        end
    end

    % ------------------------------------------------------------------
    function th = buildDiagnosticsTabContent(tab, gcfg)
        % Grouped-panel layout for tabs with only lamps/status codes and
        % no gauges/plots (currently just the Errors tab): one titled
        % panel per section, each item rendered as a full-size row
        % instead of the cramped single-strip layout used elsewhere.
        nPlots = numel(gcfg.Plots);
        if nPlots > 0
            % A plot row on top (e.g. the Errors tab's raw fault-code time
            % course) alongside the fault panels below -- reuses the same
            % axes/cursor wiring as normal tabs via buildPlotAxes so
            % refreshPlots/updateAtTime need no special-casing.
            wrapper = uigridlayout(tab, [2 1], 'RowHeight', {180,'1x'}, ...
                'Padding',[0 0 0 0], 'RowSpacing',6);
            sectionsParent = wrapper;
            [axHandles, cursorHandles, plotValueLabels, plotGrid] = buildPlotAxes(wrapper, gcfg);
            if isgraphics(plotGrid)
                plotGrid.Layout.Row = 1;
            end
        else
            sectionsParent = tab;
            axHandles = gobjects(1,0);
            cursorHandles = gobjects(1,0);
            plotValueLabels = cell(1,0);
        end

        nSections = numel(gcfg.Sections);
        ncols = min(2, nSections);
        nrows = ceil(nSections/ncols);
        outer = uigridlayout(sectionsParent, [nrows ncols], 'Padding',[8 8 8 8], ...
            'RowSpacing',10, 'ColumnSpacing',10);
        if nPlots > 0
            outer.Layout.Row = 2;
        end

        sectionHandles = struct('Lamps',{},'StatusLabels',{},'TextBlocks',{});
        for si = 1:nSections
            sec = gcfg.Sections(si);
            r = ceil(si/ncols);
            c = si - (r-1)*ncols;

            nSimple = numel(sec.Lamps) + numel(sec.StatusLabels);
            nText = numel(sec.TextBlocks);
            nItems = max(nSimple + nText, 1);
            rowHeights = [repmat({34}, 1, nSimple), repmat({150}, 1, nText)];
            if isempty(rowHeights)
                rowHeights = {34};
            end
            panel = uipanel(outer, 'Title', sec.Title, 'FontSize',13, 'FontWeight','bold');
            panel.Layout.Row = r;
            panel.Layout.Column = c;
            inner = uigridlayout(panel, [nItems 1], ...
                'RowHeight', rowHeights, 'RowSpacing',4, 'Padding',[10 10 10 10]);

            lampHandles = gobjects(1, numel(sec.Lamps));
            statusHandles = gobjects(1, numel(sec.StatusLabels));
            textHandles = gobjects(1, numel(sec.TextBlocks));
            rowIdx = 1;
            for li = 1:numel(sec.Lamps)
                card = uigridlayout(inner, [1 2], 'ColumnWidth',{34,'1x'}, 'Padding',[0 0 0 0]);
                card.Layout.Row = rowIdx;
                lp = uilamp(card, 'Color',[0.7 0.7 0.7]);
                lp.Layout.Column = 1;
                vl = uilabel(card, 'Text', sec.Lamps(li).Label, 'FontSize',12);
                vl.Layout.Column = 2;
                lampHandles(li) = lp;
                rowIdx = rowIdx + 1;
            end
            for vi = 1:numel(sec.StatusLabels)
                card = uigridlayout(inner, [1 2], 'ColumnWidth',{64,'1x'}, 'Padding',[0 0 0 0]);
                card.Layout.Row = rowIdx;
                vlbl = uilabel(card, 'Text','--', 'FontWeight','bold', 'FontSize',12, 'HorizontalAlignment','center');
                vlbl.Layout.Column = 1;
                dl = uilabel(card, 'Text', sec.StatusLabels(vi).Label, 'FontSize',12);
                dl.Layout.Column = 2;
                statusHandles(vi) = vlbl;
                rowIdx = rowIdx + 1;
            end
            for ti = 1:numel(sec.TextBlocks)
                card = uigridlayout(inner, [2 1], 'RowHeight',{18,'1x'}, 'Padding',[0 0 0 0]);
                card.Layout.Row = rowIdx;
                hl = uilabel(card, 'Text', sec.TextBlocks(ti).Label, 'FontSize',12, 'FontWeight','bold');
                hl.Layout.Row = 1;
                tb = uilabel(card, 'Text','--', 'FontSize',10.5, 'VerticalAlignment','top', 'WordWrap','on');
                tb.Layout.Row = 2;
                textHandles(ti) = tb;
                rowIdx = rowIdx + 1;
            end

            sectionHandles(si).Lamps = lampHandles;
            sectionHandles(si).StatusLabels = statusHandles;
            sectionHandles(si).TextBlocks = textHandles;
        end

        th.Gauges = gobjects(1,0);
        th.Axes = axHandles;
        th.Cursors = cursorHandles;
        th.Lamps = gobjects(1,0);
        th.StatusLabels = gobjects(1,0);
        th.Sections = sectionHandles;
        th.PlotValueLabels = plotValueLabels;
        th.BarCharts = gobjects(1,0);
    end

    % ------------------------------------------------------------------
    function th = buildBarChartTabContent(tab, gcfg)
        % Grid of bar-chart axes (currently just the Cell Voltages tab's
        % single 36-bar chart, one bar per cell). Unlike the time-series
        % Plots, a bar chart's height per category IS the scrubbed-time
        % reading -- there's nothing to plot once at load time, so this
        % builder only creates the axes/bar objects; updateBarChart (called
        % from updateTabValues, same cost model as gauges/lamps) sets the
        % bar heights on every scrub via the usual zero-order-hold sample.
        nCharts = numel(gcfg.BarCharts);
        ncols = min(2, nCharts);
        nrows = ceil(nCharts/max(ncols,1));
        tg = uigridlayout(tab, [max(nrows,1) max(ncols,1)], 'Padding',[8 8 8 8], ...
            'RowSpacing',10, 'ColumnSpacing',10);

        barHandles = struct('Bar',{},'Axes',{});
        for i = 1:nCharts
            bc = gcfg.BarCharts(i);
            r = ceil(i/ncols);
            c = i - (r-1)*ncols;

            ax = uiaxes(tg);
            ax.Layout.Row = r;
            ax.Layout.Column = c;
            title(ax, bc.Title);
            xlabel(ax, 'Cell #');
            if isempty(bc.Unit)
                ylabel(ax, bc.YLabel);
            else
                ylabel(ax, sprintf('%s (%s)', bc.YLabel, bc.Unit));
            end

            n = numel(bc.Keys);
            b = bar(ax, 1:n, nan(1,n));
            b.FaceColor = 'flat';
            b.CData = repmat([0.0000 0.4470 0.7410], n, 1);
            ax.XTick = 1:n;
            ax.XTickLabel = bc.Labels;
            ax.XLim = [0.5, n+0.5];
            if ~isempty(bc.Range)
                ax.YLim = bc.Range;
            end
            grid(ax, 'on');

            barHandles(i).Bar = b;
            barHandles(i).Axes = ax;
        end

        th.Gauges = gobjects(1,0);
        th.Axes = gobjects(1,0);
        th.Cursors = gobjects(1,0);
        th.Lamps = gobjects(1,0);
        th.StatusLabels = gobjects(1,0);
        th.Sections = struct('Lamps',{},'StatusLabels',{});
        th.PlotValueLabels = {};
        th.BarCharts = barHandles;
    end

    % ------------------------------------------------------------------
    function onLoadButton()
        filters = {'*.trc;*.txt', 'CAN trace files (*.trc, *.txt)'; ...
                   '*.trc', 'PCAN-View trace (*.trc)'; ...
                   '*.txt', 'SAMPlay log (*.txt)'};
        [file, folder] = uigetfile(filters, 'Select PCAN .trc or SAMPlay .txt trace file');
        if isequal(file,0)
            return
        end
        loadFile(fullfile(folder,file));
    end

    function loadFile(fname)
        dlg = uiprogressdlg(app.UIFigure, 'Title','Loading', ...
            'Message','Parsing trace file...', 'Indeterminate','on');
        cleanupObj = onCleanup(@() close(dlg)); %#ok<NASGU>
        try
            trace = parseTraceFile(fname);
            if isempty(trace.Time)
                uialert(app.UIFigure, 'No CAN data frames found in this file.', 'Parse Error');
                return
            end
            dlg.Message = 'Decoding signals...';
            decoded = decodeMessages(trace, app.DBC);

            app.Trace = trace;
            app.Decoded = decoded;

            [~, nameOnly, ext] = fileparts(fname);
            app.FileLabel.Text = sprintf('%s%s   |   %d frames   |   %.1f s', ...
                nameOnly, ext, numel(trace.Time), trace.Time(end));

            tEnd = max(trace.Time(end), 0.001);
            app.ViewRange = [0 tEnd];

            app.RangeLowSlider.Limits = [0 tEnd];
            app.RangeLowSlider.Value = 0;
            app.RangeHighSlider.Limits = [0 tEnd];
            app.RangeHighSlider.Value = tEnd;
            app.RangeLowSlider.Enable = 'on';
            app.RangeHighSlider.Enable = 'on';
            updateRangeLabel();

            app.TimelineSlider.Limits = app.ViewRange;
            app.TimelineSlider.Value = 0;
            app.TimelineSlider.Enable = 'on';

            refreshPlots();
            updateAtTime(0);
        catch ME
            uialert(app.UIFigure, ME.message, 'Error loading file');
        end
    end

    % ------------------------------------------------------------------
    function refreshPlots()
        for gi = 1:numel(app.Groups)
            gcfg = app.Groups(gi);
            for pi = 1:numel(gcfg.Plots)
                ax = app.TabHandles(gi).Axes(pi);
                cla(ax);
                pcfg = gcfg.Plots(pi);
                hasRightAxis = isfield(pcfg,'RightAxis') && ~isempty(pcfg.RightAxis);
                if hasRightAxis
                    yyaxis(ax, 'left');
                end
                anyPlotted = false;
                vlabs = app.TabHandles(gi).PlotValueLabels{pi};
                for ki = 1:numel(pcfg.Keys)
                    key = pcfg.Keys{ki};
                    hasLbl = ki <= numel(vlabs) && isgraphics(vlabs(ki));
                    if isKey(app.Decoded, key)
                        e = app.Decoded(key);
                        % Explicit color instead of relying on automatic
                        % ColorOrderIndex cycling -- with yyaxis (used
                        % when RightAxis is set) ax.ColorOrder collapses
                        % to a single row and every line on a side would
                        % otherwise come out identically colored.
                        col = defaultLineColor(ki);
                        ln = plot(ax, e.Time, e.Value, 'DisplayName', pcfg.Labels{ki}, 'LineWidth', 1, 'Color', col);
                        anyPlotted = true;
                        if hasLbl
                            vlabs(ki).FontColor = ln.Color;
                        end
                    elseif hasLbl
                        vlabs(ki).Text = sprintf('%s: N/A', pcfg.Labels{ki});
                        vlabs(ki).FontColor = [0.6 0.6 0.6];
                    end
                end
                if anyPlotted && numel(pcfg.Keys) > 1
                    legend(ax, 'show', 'Location','best');
                end
                if ~anyPlotted
                    text(ax, 0.5, 0.5, 'no data in this trace', 'Units','normalized', ...
                        'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
                end
                if isfield(pcfg,'YValMap') && ~isempty(pcfg.YValMap)
                    ax.YTick = cell2mat(pcfg.YValMap(:,1));
                    ax.YTickLabel = pcfg.YValMap(:,2);
                end
                if hasRightAxis
                    ax.YLim = pcfg.RightAxis.LeftLimits;
                    yyaxis(ax, 'right');
                    ax.YLim = pcfg.RightAxis.LeftLimits * pcfg.RightAxis.Factor;
                    yyaxis(ax, 'left');
                end
                ax.XLim = app.ViewRange;
                cl = xline(ax, 0, 'Color',[0.85 0.1 0.1], 'LineWidth',1.2);
                app.TabHandles(gi).Cursors(pi) = cl;
            end
        end
    end

    % ------------------------------------------------------------------
    function updateAxesXLim()
        % Cheap re-zoom: just move the axes limits, no replotting. Used
        % while dragging the view-range sliders.
        for gi = 1:numel(app.Groups)
            axArr = app.TabHandles(gi).Axes;
            for ai = 1:numel(axArr)
                if isgraphics(axArr(ai))
                    axArr(ai).XLim = app.ViewRange;
                end
            end
        end
    end

    function updateRangeLabel()
        app.RangeLabel.Text = sprintf('%.2f - %.2f s', app.ViewRange(1), app.ViewRange(2));
    end

    % ------------------------------------------------------------------
    function onSlide(val)
        if isempty(app.Trace)
            return
        end
        updateAtTime(val);
    end

    function onRangeSlide(which, val)
        if isempty(app.Trace)
            return
        end
        tEnd = app.RangeLowSlider.Limits(2);
        minGap = max(tEnd * 0.002, 1e-3);
        lo = app.RangeLowSlider.Value;
        hi = app.RangeHighSlider.Value;
        switch which
            case 'low'
                lo = max(min(val, hi - minGap), 0);
                app.RangeLowSlider.Value = lo;
            case 'high'
                hi = min(max(val, lo + minGap), tEnd);
                app.RangeHighSlider.Value = hi;
        end

        app.ViewRange = [lo hi];
        updateAxesXLim();
        updateRangeLabel();

        app.TimelineSlider.Limits = app.ViewRange;
        cVal = min(max(app.TimelineSlider.Value, lo), hi);
        app.TimelineSlider.Value = cVal;
        updateAtTime(cVal);
    end

    function onTabChanged(evt)
        if isempty(app.Trace)
            return
        end
        gi = find(app.TabList == evt.NewValue, 1);
        if ~isempty(gi)
            updateTabValues(gi, app.TimelineSlider.Value);
        end
    end

    function updateAtTime(tval)
        app.TimeLabel.Text = sprintf('t = %.2f s', tval);

        for gi = 1:numel(app.Groups)
            cursors = app.TabHandles(gi).Cursors;
            for ci = 1:numel(cursors)
                if isgraphics(cursors(ci))
                    cursors(ci).Value = tval;
                end
            end
        end

        selGi = find(app.TabList == app.TabGroup.SelectedTab, 1);
        if ~isempty(selGi)
            updateTabValues(selGi, tval);
        end
    end

    function updateTabValues(gi, tval)
        gcfg = app.Groups(gi);
        th = app.TabHandles(gi);

        updatePlotValues(gi, tval);

        for i = 1:numel(gcfg.BarCharts)
            if i <= numel(th.BarCharts)
                updateBarChart(th.BarCharts(i), gcfg.BarCharts(i), tval);
            end
        end

        for i = 1:numel(gcfg.Gauges)
            gau = th.Gauges(i);
            key = gcfg.Gauges(i).Key;
            if isKey(app.Decoded, key)
                v = sampleAtTime(app.Decoded(key), tval);
                rng = gau.Limits;
                gau.Value = min(max(v, rng(1)), rng(2));
                gau.Enable = 'on';
            else
                gau.Value = gau.Limits(1);
                gau.Enable = 'off';
            end
        end

        if ~isempty(gcfg.Sections)
            for si = 1:numel(gcfg.Sections)
                sec = gcfg.Sections(si);
                sh = th.Sections(si);
                for i = 1:numel(sec.Lamps)
                    updateLamp(sh.Lamps(i), sec.Lamps(i).Key, tval);
                end
                for i = 1:numel(sec.StatusLabels)
                    updateStatus(sh.StatusLabels(i), sec.StatusLabels(i).Key, tval);
                end
                for i = 1:numel(sec.TextBlocks)
                    updateTextBlock(sh.TextBlocks(i), sec.TextBlocks(i), tval);
                end
            end
        else
            for i = 1:numel(gcfg.Lamps)
                updateLamp(th.Lamps(i), gcfg.Lamps(i).Key, tval);
            end
            for i = 1:numel(gcfg.StatusLabels)
                updateStatus(th.StatusLabels(i), gcfg.StatusLabels(i).Key, tval);
            end
        end
    end

    function updatePlotValues(gi, tval)
        % Numeric readout to the right of each plot, sampled at the
        % scrubbed time with the same zero-order-hold as gauges/lamps.
        % Only called for the currently selected tab (see updateTabValues).
        gcfg = app.Groups(gi);
        th = app.TabHandles(gi);
        for pi = 1:numel(gcfg.Plots)
            pcfg = gcfg.Plots(pi);
            if pi > numel(th.PlotValueLabels)
                continue
            end
            vlabs = th.PlotValueLabels{pi};
            for ki = 1:numel(pcfg.Keys)
                if ki > numel(vlabs) || ~isgraphics(vlabs(ki))
                    continue
                end
                lblName = pcfg.Labels{ki};
                key = pcfg.Keys{ki};
                if isKey(app.Decoded, key)
                    e = app.Decoded(key);
                    v = sampleAtTime(e, tval);
                    if isnan(v)
                        valStr = 'N/A';
                    elseif ~isempty(e.ValMap)
                        valStr = valMapLookup(v, e.ValMap);
                    elseif isfield(pcfg,'YValMap') && ~isempty(pcfg.YValMap)
                        valStr = valMapLookup(v, pcfg.YValMap);
                    elseif isempty(e.Unit)
                        valStr = sprintf('%g', v);
                    else
                        valStr = sprintf('%g %s', v, e.Unit);
                    end
                    if isfield(pcfg,'RightAxis') && ~isempty(pcfg.RightAxis) && ~isnan(v)
                        pct = v * pcfg.RightAxis.Factor;
                        valStr = sprintf('%s  (%.1f %s)', valStr, pct, pcfg.RightAxis.Unit);
                    end
                    vlabs(ki).Text = sprintf('%s:\n%s', lblName, valStr);
                else
                    vlabs(ki).Text = sprintf('%s:\nN/A', lblName);
                end
            end
        end
    end

    function updateBarChart(bh, bc, tval)
        if ~isgraphics(bh.Bar)
            return
        end
        n = numel(bc.Keys);
        vals = nan(1,n);
        for k = 1:n
            key = bc.Keys{k};
            if isKey(app.Decoded, key)
                vals(k) = sampleAtTime(app.Decoded(key), tval);
            end
        end
        bh.Bar.YData = vals;

        % Color-code: gray for a cell missing from this trace, green for
        % the current max, red for the current min, blue for the rest --
        % makes the worst-imbalanced cell(s) jump out at a glance instead
        % of requiring a manual scan of 36 bars.
        cdata = repmat([0.0000 0.4470 0.7410], n, 1);
        present = ~isnan(vals);
        if any(present)
            [~, iMax] = max(vals);
            [~, iMin] = min(vals);
            cdata(iMax,:) = [0.2 0.75 0.2];
            cdata(iMin,:) = [0.75 0.2 0.2];
        end
        cdata(~present,:) = repmat([0.7 0.7 0.7], sum(~present), 1);
        bh.Bar.CData = cdata;
    end

    function updateLamp(lp, key, tval)
        if isKey(app.Decoded, key)
            v = sampleAtTime(app.Decoded(key), tval);
            if v ~= 0
                lp.Color = [0.2 0.75 0.2];
            else
                lp.Color = [0.75 0.2 0.2];
            end
        else
            lp.Color = [0.7 0.7 0.7];
        end
    end

    function updateStatus(lbl, key, tval)
        if isKey(app.Decoded, key)
            e = app.Decoded(key);
            v = sampleAtTime(e, tval);
            lbl.Text = valMapLookup(v, e.ValMap);
        else
            lbl.Text = 'N/A';
        end
    end

    function updateTextBlock(lbl, cfg, tval)
        if isKey(app.Decoded, cfg.Key)
            v = sampleAtTime(app.Decoded(cfg.Key), tval);
        else
            v = NaN;
        end
        [lines, severity] = cfg.Formatter(v);
        lbl.Text = lines;
        switch severity
            case 'critical'
                lbl.FontColor = [0.75 0.1 0.1];
            case 'warning'
                lbl.FontColor = [0.85 0.55 0.05];
            case 'ok'
                lbl.FontColor = [0.2 0.6 0.2];
            otherwise
                lbl.FontColor = [0.5 0.5 0.5];
        end
    end

end

% ---- plain (non-nested) helper functions --------------------------
function trace = parseTraceFile(fname)
% Dispatches by content, not extension: SAMPlay logger exports are plain
% comma-separated rows with no header and no "DT" token (unlike PCAN-View
% .trc), so sniff the first non-empty line rather than trusting the file
% extension (SAMPlay logs use plain ".txt").
fid = fopen(fname,'r');
firstLine = '';
if fid > 0
    while true
        l = fgetl(fid);
        if ~ischar(l)
            break
        end
        if ~isempty(strtrim(l))
            firstLine = l;
            break
        end
    end
    fclose(fid);
end
isSamPlay = ischar(firstLine) && ~isempty(regexp(firstLine, ...
    '^\s*[\d.]+,\s*[0-9A-Fa-f]+,\s*\d+,\s*[0-9A-Fa-f]{2}\s*,', 'once'));
if isSamPlay
    trace = parseSAMPlay(fname);
else
    trace = parseTRC(fname);
end
end

function v = sampleAtTime(entry, tval)
if isempty(entry.Time)
    v = NaN;
elseif tval <= entry.Time(1)
    v = entry.Value(1);
else
    v = interp1(entry.Time, entry.Value, tval, 'previous', 'extrap');
end
end

function col = defaultLineColor(idx)
% MATLAB's standard 7-color axes ColorOrder, hardcoded -- needed because
% ax.ColorOrder collapses to a single row once yyaxis is active (see
% refreshPlots), so it can't be read back off the axes for cycling.
palette = [ ...
    0.0000 0.4470 0.7410
    0.8500 0.3250 0.0980
    0.9290 0.6940 0.1250
    0.4940 0.1840 0.5560
    0.4660 0.6740 0.1880
    0.3010 0.7450 0.9330
    0.6350 0.0780 0.1840 ];
col = palette(mod(idx-1, size(palette,1)) + 1, :);
end

function s = valMapLookup(v, valMap)
if isempty(valMap)
    s = sprintf('%g', v);
    return
end
for i = 1:size(valMap,1)
    if valMap{i,1} == v
        s = valMap{i,2};
        return
    end
end
s = sprintf('%g (unknown)', v);
end
