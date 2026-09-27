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
app.IsPlaying = false;   % true while real-time playback is running
app.PlayTimer = [];      % timer object driving playback ticks, created lazily
app.PlayStartTic = [];   % tic() reference at the moment playback (re)started
app.PlayStartTraceTime = 0;  % trace time (s) the current playback run started from

% CAN TX (PEAK adapter) state -- see buildCanOutputTabContent
app.CanChannel    = [];       % Vehicle Network Toolbox can.Channel once connected
app.CanConnected  = false;
app.CanArmed      = false;    % true = actually transmit on play-tick/step, not just connected
app.CanDeviceRows = table(); % rows currently listed in the device dropdown
app.LastTxTime    = 0;        % trace time already transmitted up to (avoids backlog bursts)
app.CanFramesSent = 0;

% Efficiency map (Kennfeld) state -- see buildEfficiencyMapTabContent
app.KennfeldSets = emptyKennfeldSets();
app.CurrentTraceLabel = '';   % name of the currently loaded trace, used as the default dataset label
% Remembered as defaults for showKennfeldSettingsDialog's controls,
% updated every time that dialog is confirmed. Steady-state defaults to ON
% (1 s / 150 rpm / 2 Nm): transients carry 3-8 pp extra apparent loss and
% about twice the scatter in every trace analysed so far.
app.KennfeldSSEnabledDefault  = true;
app.KennfeldWindowDefault     = 1;      % s
app.KennfeldMaxDSpeedDefault  = 150;    % rpm
app.KennfeldMaxDTorqueDefault = 2;      % Nm
app.KennfeldAuxDefault        = true;   % subtract auxiliary (12 V/DCDC) base load from P_batt
app.KennfeldKModeDefault      = 'auto'; % torque gain k: 'auto' (mirror-point) | 'manual' | 'off'
app.KennfeldKManualDefault    = 1;      % manual k, also the fallback when 'auto' can't estimate

% Cell internal resistance tab state -- see buildCellResistanceTabContent
app.CellRes = [];            % result struct from computeCellResistance, [] = not computed yet
app.CellResSelected = 1;     % cell shown in the dV/dI scatter

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
        app.UIFigure.CloseRequestFcn = @(src,~) onCloseRequest(src);
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

        % CAN output tab: not one of the data-driven app.Groups tabs (it
        % doesn't show decoded signals), so it's built directly here and
        % deliberately left out of app.TabList/app.TabHandles -- the
        % onTabChanged/updateAtTime loops key off app.TabList, and a
        % find() that doesn't match it is a harmless no-op.
        canTab = uitab(app.TabGroup, 'Title', 'CAN Ausgabe (PEAK)');
        buildCanOutputTabContent(canTab);
        refreshCanDevices();

        % Efficiency map tab: same reasoning as the CAN output tab above --
        % it doesn't show decoded signals against the scrub cursor, so it's
        % built directly here and left out of app.TabList/app.TabHandles.
        kennfeldTab = uitab(app.TabGroup, 'Title', 'Effizienz-Kennfeld');
        buildEfficiencyMapTabContent(kennfeldTab);

        % Cell internal resistance tab: same reasoning again -- a whole-
        % trace analysis computed on button press, not scrub-driven.
        cellResTab = uitab(app.TabGroup, 'Title', 'Zell-Innenwiderstand');
        buildCellResistanceTabContent(cellResTab);

        bottomGrid = uigridlayout(app.MainGrid, [2 1], 'RowHeight', {50,50}, 'RowSpacing',4, 'Padding',[8 8 8 8]);
        bottomGrid.Layout.Row = 3;

        cursorRow = uigridlayout(bottomGrid, [1 5], 'ColumnWidth', {36,36,36,'1x',150}, 'Padding',[0 0 0 0]);
        cursorRow.Layout.Row = 1;
        app.StepBackButton = uibutton(cursorRow, 'push', 'Text', char(9198), 'FontSize',14, ...
            'Enable','off', 'Tooltip','Previous CAN message', ...
            'ButtonPushedFcn', @(~,~) stepFrame(-1));
        app.StepBackButton.Layout.Column = 1;
        app.PlayPauseButton = uibutton(cursorRow, 'push', 'Text', char(9654), 'FontSize',14, ...
            'Enable','off', 'Tooltip','Play / Pause', ...
            'ButtonPushedFcn', @(~,~) onPlayPause());
        app.PlayPauseButton.Layout.Column = 2;
        app.StepForwardButton = uibutton(cursorRow, 'push', 'Text', char(9197), 'FontSize',14, ...
            'Enable','off', 'Tooltip','Next CAN message', ...
            'ButtonPushedFcn', @(~,~) stepFrame(1));
        app.StepForwardButton.Layout.Column = 3;
        app.TimelineSlider = uislider(cursorRow, 'Limits',[0 1], 'Value',0, 'Enable','off', ...
            'ValueChangingFcn', @(~,evt) onSlide(evt.Value), ...
            'ValueChangedFcn',  @(~,evt) onSlide(evt.Value));
        app.TimelineSlider.Layout.Column = 4;
        app.TimeLabel = uilabel(cursorRow, 'Text','t = -- s', 'HorizontalAlignment','right', 'FontSize',13);
        app.TimeLabel.Layout.Column = 5;

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
    % CAN output tab: replays the loaded trace's raw frames onto a real
    % CAN bus through a PEAK-System USB adapter (Vehicle Network Toolbox),
    % driven by the SAME Play/Pause/step-forward/step-back controls used
    % for on-screen scrubbing -- so a diagnostic display wired to this
    % adapter sees the exact same message stream, at the same real-time
    % pace or single-stepped, without needing the vehicle.
    function buildCanOutputTabContent(tab)
        tg = uigridlayout(tab, [6 1], 'RowHeight', {40,40,40,32,40,'1x'}, ...
            'RowSpacing',8, 'Padding',[12 12 12 12]);

        deviceRow = uigridlayout(tg, [1 3], 'ColumnWidth', {'1x',120,120}, 'Padding',[0 0 0 0]);
        deviceRow.Layout.Row = 1;
        app.CanDeviceDropdown = uidropdown(deviceRow, 'Items',{'--'}, 'Enable','off');
        app.CanDeviceDropdown.Layout.Column = 1;
        refreshBtn = uibutton(deviceRow, 'push', 'Text','Aktualisieren', ...
            'ButtonPushedFcn', @(~,~) refreshCanDevices());
        refreshBtn.Layout.Column = 2;
        app.CanConnectButton = uibutton(deviceRow, 'push', 'Text','Verbinden', ...
            'Enable','off', 'ButtonPushedFcn', @(~,~) onCanConnectButton());
        app.CanConnectButton.Layout.Column = 3;

        bitrateRow = uigridlayout(tg, [1 2], 'ColumnWidth', {140,'1x'}, 'Padding',[0 0 0 0]);
        bitrateRow.Layout.Row = 2;
        uilabel(bitrateRow, 'Text','Bitrate (bit/s):', 'FontSize',13);
        app.CanBitrateDropdown = uidropdown(bitrateRow, ...
            'Items', {'125000','250000','500000','1000000'}, 'Value','125000');

        armRow = uigridlayout(tg, [1 2], 'ColumnWidth', {320,'1x'}, 'Padding',[0 0 0 0]);
        armRow.Layout.Row = 3;
        app.CanArmCheckbox = uicheckbox(armRow, 'Text','Senden bei Play/Schritt aktivieren (armed)', ...
            'Value', false, 'Enable','off', 'ValueChangedFcn', @(src,~) onCanArmChanged(src.Value));
        app.CanStatusLabel = uilabel(armRow, 'Text','Nicht verbunden.', 'FontSize',13, 'WordWrap','on');

        statsRow = uigridlayout(tg, [1 2], 'ColumnWidth', {200,'1x'}, 'Padding',[0 0 0 0]);
        statsRow.Layout.Row = 4;
        app.CanStatsLabel = uilabel(statsRow, 'Text','Gesendet: 0', 'FontSize',12);
        app.CanLastFrameLabel = uilabel(statsRow, 'Text','Letzter Frame: --', 'FontSize',12);

        uilabel(tg, 'Text', ['Hinweis: Bei aktivem "Senden"-Haken werden beim Abspielen/Schritt ' ...
            'echte CAN-Frames auf den angeschlossenen Bus gesendet -- beim Anschluss an ein ' ...
            'reales Fahrzeug entsprechend vorsichtig verwenden.'], ...
            'FontColor',[0.75 0.4 0.0], 'FontAngle','italic', 'FontSize',11, 'WordWrap','on');

        app.CanLogArea = uitextarea(tg, 'Value', {'Bereit.'}, 'Editable','off');
    end

    function refreshCanDevices()
        try
            allRows = canChannelList();
        catch
            allRows = table();
        end
        isPeak = ~isempty(allRows) && any(strcmp(cellstr(string(allRows.Vendor)), 'PEAK-System'));
        if isPeak
            rows = allRows(strcmp(cellstr(string(allRows.Vendor)), 'PEAK-System'), :);
            fallbackNote = '';
        elseif ~isempty(allRows)
            rows = allRows;
            fallbackNote = ' (kein PEAK-Gerät gefunden -- zeige verfügbare Testkanäle)';
        else
            rows = table();
            fallbackNote = '';
        end
        app.CanDeviceRows = rows;

        if isempty(rows) || height(rows) == 0
            app.CanDeviceDropdown.Items = {'Kein Gerät gefunden'};
            app.CanDeviceDropdown.ItemsData = 0;
            app.CanDeviceDropdown.Enable = 'off';
            app.CanConnectButton.Enable = 'off';
        else
            items = cell(height(rows),1);
            for i = 1:height(rows)
                items{i} = sprintf('%s -- %s Kanal %d', string(rows.Vendor(i)), string(rows.Device(i)), rows.Channel(i));
            end
            app.CanDeviceDropdown.Items = items;
            app.CanDeviceDropdown.ItemsData = 1:height(rows);
            app.CanDeviceDropdown.Value = 1;
            app.CanDeviceDropdown.Enable = 'on';
            app.CanConnectButton.Enable = 'on';
        end

        if ~app.CanConnected
            if isempty(rows) || height(rows) == 0
                app.CanStatusLabel.Text = ['Nicht verbunden. Kein Gerät gefunden -- PEAK-Adapter ' ...
                    'anschließen bzw. PCAN-Basic-Treiber installieren und "Aktualisieren" drücken.'];
            else
                app.CanStatusLabel.Text = ['Nicht verbunden.' fallbackNote];
            end
        end
    end

    function onCanConnectButton()
        if app.CanConnected
            doCanDisconnect();
        else
            doCanConnect();
        end
    end

    function doCanConnect()
        if isempty(app.CanDeviceRows) || height(app.CanDeviceRows) == 0
            return
        end
        idx = app.CanDeviceDropdown.Value;
        row = app.CanDeviceRows(idx,:);
        bitrate = str2double(app.CanBitrateDropdown.Value);
        try
            ch = canChannel(char(string(row.Vendor)), char(string(row.Device)));
            configBusSpeed(ch, bitrate);
            start(ch);
            app.CanChannel = ch;
            app.CanConnected = true;
            app.CanFramesSent = 0;
            app.CanStatsLabel.Text = 'Gesendet: 0';
            app.CanLastFrameLabel.Text = 'Letzter Frame: --';
            app.CanConnectButton.Text = 'Trennen';
            app.CanDeviceDropdown.Enable = 'off';
            app.CanBitrateDropdown.Enable = 'off';
            app.CanArmCheckbox.Enable = 'on';
            msg = sprintf('Verbunden: %s %s Kanal %d @ %d bit/s', string(row.Vendor), string(row.Device), row.Channel, bitrate);
            app.CanStatusLabel.Text = msg;
            appendCanLog(msg);
        catch ME
            app.CanStatusLabel.Text = ['Verbindungsfehler: ' ME.message];
            appendCanLog(['FEHLER beim Verbinden: ' ME.message]);
        end
    end

    function doCanDisconnect()
        app.CanArmCheckbox.Value = false;
        app.CanArmed = false;
        try
            if ~isempty(app.CanChannel) && isvalid(app.CanChannel)
                stop(app.CanChannel);
                delete(app.CanChannel);
            end
        catch
        end
        app.CanChannel = [];
        app.CanConnected = false;
        app.CanConnectButton.Text = 'Verbinden';
        app.CanDeviceDropdown.Enable = 'on';
        app.CanBitrateDropdown.Enable = 'on';
        app.CanArmCheckbox.Enable = 'off';
        app.CanStatusLabel.Text = 'Nicht verbunden.';
        appendCanLog('Getrennt.');
    end

    function onCanArmChanged(val)
        app.CanArmed = val;
        if val
            % Arm from the cursor's current position -- otherwise every
            % frame between t=0 and "now" would burst-send the instant
            % the checkbox is ticked mid-trace.
            app.LastTxTime = app.TimelineSlider.Value;
            appendCanLog('Senden aktiviert.');
        else
            appendCanLog('Senden deaktiviert.');
        end
    end

    function appendCanLog(msg)
        if ~isgraphics(app.CanLogArea)
            return
        end
        line = sprintf('[%s] %s', datestr(now,'HH:MM:SS'), msg);
        cur = app.CanLogArea.Value;
        cur = [{line}; cur];
        if numel(cur) > 50
            cur = cur(1:50);
        end
        app.CanLogArea.Value = cur;
    end

    % Sends every trace frame with tFrom < Time <= tTo, in order -- called
    % once per playback tick with the [previous tick, this tick] window.
    function txFramesInRange(tFrom, tTo)
        if ~app.CanConnected || ~app.CanArmed || isempty(app.Trace) || tTo <= tFrom
            return
        end
        idx = find(app.Trace.Time > tFrom & app.Trace.Time <= tTo);
        sendFrameIndices(idx);
    end

    % Sends exactly the trace frame(s) at the given row index/indices --
    % used for single-message step and for the end-of-range playback tick.
    function sendFrameIndices(idx)
        if isempty(idx) || ~app.CanConnected || ~app.CanArmed
            return
        end
        try
            n = numel(idx);
            for k = 1:n
                ri = idx(k);
                id = app.Trace.ID(ri);
                dlc = app.Trace.DLC(ri);
                m = canMessage(id, id > 2047, dlc);
                if dlc > 0
                    m.Data = app.Trace.Data(ri,1:dlc);
                end
                if k == 1
                    msgs = m;
                else
                    msgs(k) = m; %#ok<AGROW>
                end
            end
            transmit(app.CanChannel, msgs);
            app.CanFramesSent = app.CanFramesSent + n;
            lastRi = idx(end);
            app.CanStatsLabel.Text = sprintf('Gesendet: %d', app.CanFramesSent);
            app.CanLastFrameLabel.Text = sprintf('Letzter Frame: ID 0x%03X, %d Byte, t=%.3fs', ...
                app.Trace.ID(lastRi), app.Trace.DLC(lastRi), app.Trace.Time(lastRi));
        catch ME
            app.CanStatusLabel.Text = ['Sendefehler: ' ME.message];
            appendCanLog(['FEHLER beim Senden: ' ME.message]);
        end
    end

    % ------------------------------------------------------------------
    % Efficiency map (Kennfeld) tab: X = Drehzahl (Motor_speed, rpm),
    % Y = Drehmoment (skai_torque, "Ist Moment", Nm), color = Gesamt-
    % wirkungsgrad. Computation only runs on button press, gated behind a
    % settings/confirmation popup (see showKennfeldSettingsDialog /
    % onKennfeldCalcButton) -- never tied to the scrub cursor.
    %
    % Efficiency definition:
    %   P_mech = k * skai_torque [Nm] * (Motor_speed [rpm] * 2*pi/60) (shaft power, W)
    %   P_batt = -(Battery_voltage [V] * Battery_current [A]) - P_aux (power OUT of
    %            the battery minus the auxiliary base load, W)
    %   eta    = P_mech / P_batt
    % Battery_current is 0x386 (10 Hz), linearly interpolated -- 0x186 is
    % only sent at 1 Hz by both BMS variants. k corrects the motor
    % controller's torque estimate, P_aux the 12 V/DCDC base load; both are
    % estimated per trace, see computeKennfeldSet / estimateTorqueGain /
    % estimateAuxPower at the bottom of this file.
    % The minus sign on P_batt is not arbitrary: can_io.c accumulates ride
    % energy consumption as
    %   EnergySinceLastTick = currentCounter * mainVoltage * -0.00000108507 / currentAdded
    % (can_io.c, ~line 1283) from the same raw current field this app's
    % Battery_current is decoded from (mainCurrentFast/mainCurrentSlow) --
    % negating raw current*voltage to get a POSITIVE "energy used" while
    % driving means raw current is NEGATIVE while discharging/driving and
    % POSITIVE while charging. With that sign flip, P_mech and P_batt land
    % on the same sign together in both quadrants (motoring: both
    % positive; regen braking: both negative), so eta comes out positive
    % without special-casing direction.
    %
    % One point per "Ist Moment" sample (skai_torque's own timestamps).
    % Speed is zero-order-hold sampled at those timestamps (same 10 Hz
    % controller), battery V/I are linearly interpolated.
    %
    % Steady-state filter: a point is kept only if both Speed and Torque
    % stay within a small band over a time window centered on that sample
    % (see computeSteadyStateMask below) -- i.e. the drivetrain isn't
    % mid-transient (accelerating/braking) at that instant. On by default.
    % The filter, aux subtraction and torque correction all live only in
    % the settings popup, not as permanent tab controls -- the popup
    % remembers the last-used values (app.KennfeldSSEnabledDefault etc.)
    % as its next set of defaults, so the tab body itself stays uncluttered.
    function buildEfficiencyMapTabContent(tab)
        tg = uigridlayout(tab, [3 1], 'RowHeight', {40,220,'1x'}, 'RowSpacing',8, 'Padding',[12 12 12 12]);

        topRow = uigridlayout(tg, [1 3], 'ColumnWidth', {260,240,'1x'}, 'Padding',[0 0 0 0]);
        topRow.Layout.Row = 1;
        app.KennfeldCalcButton = uibutton(topRow, 'push', 'Text','Aus aktueller Messung berechnen...', ...
            'ButtonPushedFcn', @(~,~) onKennfeldCalcButton());
        app.KennfeldMultiButton = uibutton(topRow, 'push', 'Text','Mehrere Messungen laden...', ...
            'Tooltip','Mehrere .trc/.txt-Dateien nur fürs Kennfeld laden (die aktuell angezeigte Messung bleibt unverändert)', ...
            'ButtonPushedFcn', @(~,~) onKennfeldMultiLoadButton());
        app.KennfeldStatusLabel = uilabel(topRow, 'Text', ...
            'Noch keine Messung geladen.', 'FontSize',12, 'WordWrap','on');

        % Left: scrollable list of datasets, one row per dataset with its
        % own visibility checkbox (show/hide without losing the computed
        % points) and its own "Entfernen" button (delete outright) --
        % replaces the old single multi-select listbox + one shared
        % Entfernen button, so toggling a dataset on/off is a single click
        % instead of select-then-click-a-separate-button.
        % Right: the dataset-list-wide actions (clear all / persist to
        % disk / axis scaling), stacked vertically so they read as one
        % group distinct from the per-dataset rows.
        midRow = uigridlayout(tg, [1 2], 'ColumnWidth', {'1x',170}, 'Padding',[0 0 0 0], 'ColumnSpacing',8);
        midRow.Layout.Row = 2;
        app.KennfeldDatasetPanel = uipanel(midRow, 'Title','Datensätze', 'FontSize',12, 'Scrollable','on');
        app.KennfeldDatasetPanel.Layout.Column = 1;

        actionCol = uigridlayout(midRow, [5 1], 'RowHeight', repmat({32},1,5), 'RowSpacing',6, 'Padding',[0 0 0 0]);
        actionCol.Layout.Column = 2;
        uibutton(actionCol, 'push', 'Text','Alle löschen', ...
            'ButtonPushedFcn', @(~,~) onKennfeldClearButton());
        uibutton(actionCol, 'push', 'Text','Speichern...', ...
            'ButtonPushedFcn', @(~,~) onKennfeldSaveButton());
        uibutton(actionCol, 'push', 'Text','Laden...', ...
            'ButtonPushedFcn', @(~,~) onKennfeldLoadButton());
        uibutton(actionCol, 'push', 'Text','Achsen auf Daten skalieren', ...
            'Tooltip','X = [0, max Drehzahl], Y = [0, max Moment] der aktuell sichtbaren Punkte', ...
            'ButtonPushedFcn', @(~,~) onKennfeldScaleButton());
        uibutton(actionCol, 'push', 'Text','3D-Kennfeldfläche...', ...
            'Tooltip','Rastert die sichtbaren Punkte zu einer 3D-Fläche (Mittelwert je Zelle)', ...
            'ButtonPushedFcn', @(~,~) onKennfeld3DButton());

        app.KennfeldAxes = uiaxes(tg);
        app.KennfeldAxes.Layout.Row = 3;
        applyKennfeldColors(app.KennfeldAxes);

        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
    end

    % Modal settings/confirmation popup, shown on every "...berechnen..."
    % click. Combines what used to be two separate asks (a plain confirm
    % dialog, and permanently-visible steady-state controls on the tab)
    % into one step: reviewing the trace/sample count IS now the same
    % moment as choosing the steady-state filter, and nothing runs until
    % "Berechnen" here is clicked. uiwait/uiresume (not uiconfirm, which
    % can't host custom controls like checkboxes/edit fields) blocks the
    % caller until the dialog is dismissed either way.
    % fileNames: optional cellstr -- when non-empty (multi-file load), the
    % popup additionally shows one checkbox per file in a scrollable list,
    % returned as settings.Selected (logical, same order as fileNames).
    function settings = showKennfeldSettingsDialog(headerText, fileNames)
        settings = struct('Proceed',false, 'SteadyState',false, 'Window',2, 'MaxDSpeed',100, ...
            'MaxDTorque',2, 'Aux',false, 'KMode','off', 'KManual',1, ...
            'Selected',true(numel(fileNames),1));
        hasFiles = ~isempty(fileNames);

        mainPos = app.UIFigure.Position;
        dlgW = 560;
        if hasFiles
            dlgH = 660;
        else
            dlgH = 400;
        end
        dlgPos = [mainPos(1)+(mainPos(3)-dlgW)/2, mainPos(2)+(mainPos(4)-dlgH)/2, dlgW, dlgH];
        d = uifigure('Name','Kennfeld berechnen', 'Position',dlgPos, 'WindowStyle','modal', 'Resize',matlab.lang.OnOffSwitchState(hasFiles));
        d.CloseRequestFcn = @(~,~) onCancel();

        if hasFiles
            dg = uigridlayout(d, [8 1], 'RowHeight', {40,'1x',26,60,26,48,36,36}, 'RowSpacing',10, 'Padding',[16 16 16 16]);
        else
            dg = uigridlayout(d, [7 1], 'RowHeight', {60,26,60,26,48,'1x',36}, 'RowSpacing',10, 'Padding',[16 16 16 16]);
        end
        uilabel(dg, 'Text', headerText, 'WordWrap','on', 'FontSize',13);

        fileChecks = gobjects(0);
        if hasFiles
            filePanel = uipanel(dg, 'Title','Messungen');
            nF = numel(fileNames);
            fileGrid = uigridlayout(filePanel, [nF+1 1], 'RowHeight', [{26}, repmat({22},1,nF)], ...
                'RowSpacing',2, 'Padding',[6 6 6 6], 'Scrollable','on');
            allRow = uigridlayout(fileGrid, [1 3], 'ColumnWidth', {80,80,'1x'}, 'Padding',[0 0 0 0]);
            uibutton(allRow, 'push', 'Text','Alle', 'ButtonPushedFcn', @(~,~) setAllChecks(true));
            uibutton(allRow, 'push', 'Text','Keine', 'ButtonPushedFcn', @(~,~) setAllChecks(false));
            fileChecks = gobjects(nF, 1);
            for f = 1:nF
                label = fileNames{f};
                if any(strcmp({app.KennfeldSets.Label}, label))
                    label = [label '   (vorhanden, wird ersetzt)'];
                end
                fileChecks(f) = uicheckbox(fileGrid, 'Text', label, 'Value', true);
            end
        end

        ssCheck = uicheckbox(dg, 'Text','Nur Steady-State-Punkte auswerten', ...
            'Value', app.KennfeldSSEnabledDefault, 'ValueChangedFcn', @(src,~) toggleFields(src.Value));

        paramGrid = uigridlayout(dg, [2 3], 'ColumnWidth', {'1x','1x','1x'}, 'RowHeight', {18,26}, ...
            'Padding',[0 0 0 0], 'ColumnSpacing',10, 'RowSpacing',2);
        uilabel(paramGrid, 'Text','Fenster (s)');
        uilabel(paramGrid, 'Text','Max. |ΔDrehzahl| (rpm)');
        uilabel(paramGrid, 'Text','Max. |ΔMoment| (Nm)');
        winField    = uieditfield(paramGrid, 'numeric', 'Value', app.KennfeldWindowDefault,    'Limits',[0.05 60]);
        dSpeedField = uieditfield(paramGrid, 'numeric', 'Value', app.KennfeldMaxDSpeedDefault,  'Limits',[0 20000]);
        dTorqueField= uieditfield(paramGrid, 'numeric', 'Value', app.KennfeldMaxDTorqueDefault, 'Limits',[0 500]);

        auxCheck = uicheckbox(dg, 'Text','Grundlast (Nebenverbraucher/DCDC) von der Batterieleistung abziehen', ...
            'Value', app.KennfeldAuxDefault, ...
            'Tooltip', ['Aus dem Stillstand der Messung geschätzt: konstant (Median) oder, wenn der ' ...
                        'DCDC-12V-Strom die Stillstandsleistung erklärt (r >= 0,5), als a + b * I_12V.']);

        kModes  = {'auto','manual','off'};
        kLabels = {'Auto (Spiegelpunkt-Schätzung)','Manuell','Aus (k = 1)'};
        kGrid = uigridlayout(dg, [2 2], 'ColumnWidth', {'2x','1x'}, 'RowHeight', {18,26}, ...
            'Padding',[0 0 0 0], 'ColumnSpacing',10, 'RowSpacing',2);
        uilabel(kGrid, 'Text','Momentkorrektur k (P_mech = k · M · ω)', ...
            'Tooltip', ['Auto: k aus Motor- vs. Generatorbetrieb bei gleichem |M| und n geschätzt ' ...
                        '(gleiche Verluste in beiden Richtungen) -- braucht Rekuperation in der Messung.']);
        uilabel(kGrid, 'Text','k manuell / Fallback');
        kDrop = uidropdown(kGrid, 'Items', kLabels, 'ItemsData', kModes, ...
            'Value', app.KennfeldKModeDefault, 'ValueChangedFcn', @(src,~) toggleKField(src.Value));
        kField = uieditfield(kGrid, 'numeric', 'Value', app.KennfeldKManualDefault, 'Limits',[0.1 5], ...
            'Tooltip','Bei "Auto" nur verwendet, wenn die Messung zu wenig Rekuperation für eine Schätzung enthält.');

        uilabel(dg, 'Text','Ein bereits vorhandener Datensatz mit gleichem Namen wird ersetzt.', ...
            'FontColor',[0.55 0.55 0.55], 'FontSize',11, 'WordWrap','on', 'VerticalAlignment','top');

        btnRow = uigridlayout(dg, [1 2], 'ColumnWidth', {'1x','1x'}, 'Padding',[0 0 0 0], 'ColumnSpacing',10);
        uibutton(btnRow, 'push', 'Text','Berechnen', 'ButtonPushedFcn', @(~,~) onOk());
        uibutton(btnRow, 'push', 'Text','Abbrechen', 'ButtonPushedFcn', @(~,~) onCancel());

        toggleFields(ssCheck.Value);
        toggleKField(kDrop.Value);
        uiwait(d);

        function toggleKField(mode)
            kField.Enable = matlab.lang.OnOffSwitchState(~strcmp(mode, 'off'));
        end

        function setAllChecks(val)
            for c = 1:numel(fileChecks)
                fileChecks(c).Value = val;
            end
        end
        function toggleFields(en)
            if en
                st = 'on';
            else
                st = 'off';
            end
            winField.Enable = st;
            dSpeedField.Enable = st;
            dTorqueField.Enable = st;
        end
        function onOk()
            settings.Proceed     = true;
            settings.SteadyState = ssCheck.Value;
            settings.Window      = winField.Value;
            settings.MaxDSpeed   = dSpeedField.Value;
            settings.MaxDTorque  = dTorqueField.Value;
            settings.Aux         = auxCheck.Value;
            settings.KMode       = kDrop.Value;
            settings.KManual     = kField.Value;
            if hasFiles
                settings.Selected = arrayfun(@(c) c.Value, fileChecks);
                if ~any(settings.Selected)
                    uialert(d, 'Keine Messung angehakt.', 'Nichts ausgewählt');
                    return
                end
            end
            % Remembered as this dialog's defaults next time it opens.
            app.KennfeldSSEnabledDefault  = settings.SteadyState;
            app.KennfeldWindowDefault     = settings.Window;
            app.KennfeldMaxDSpeedDefault  = settings.MaxDSpeed;
            app.KennfeldMaxDTorqueDefault = settings.MaxDTorque;
            app.KennfeldAuxDefault        = settings.Aux;
            app.KennfeldKModeDefault      = settings.KMode;
            app.KennfeldKManualDefault    = settings.KManual;
            uiresume(d);
            delete(d);
        end
        function onCancel()
            uiresume(d);
            delete(d);
        end
    end

    function onKennfeldCalcButton()
        if isempty(app.Trace)
            uialert(app.UIFigure, 'Bitte zuerst eine Messung (.trc/.txt) laden.', 'Keine Messung geladen');
            return
        end

        missing = kennfeldMissingKeys(app.Decoded);
        if ~isempty(missing)
            uialert(app.UIFigure, ...
                sprintf('Diese Messung enthält nicht alle benötigten Signale:\n%s', strjoin(missing, newline)), ...
                'Signale fehlen');
            return
        end

        torqueEntry = app.Decoded(kennfeldKeys().Torque);
        nSamples = numel(torqueEntry.Time);

        settings = showKennfeldSettingsDialog(sprintf( ...
            'Kennfeld für "%s" berechnen?\n%d Ist-Moment-Samples in dieser Messung.', ...
            app.CurrentTraceLabel, nSamples), {});
        if ~settings.Proceed
            return
        end

        dlg = uiprogressdlg(app.UIFigure, 'Title','Kennfeld', ...
            'Message','Berechne Effizienzpunkte...', 'Indeterminate','on');
        cleanupObj = onCleanup(@() close(dlg)); %#ok<NASGU>

        newSet = computeKennfeldSet(app.Decoded, app.CurrentTraceLabel, settings);
        storeKennfeldSet(newSet);

        app.KennfeldStatusLabel.Text = sprintf(...
            '%s: %d Punkte (von %d Ist-Moment-Samples, %d verworfen). %s | %s', ...
            newSet.Label, newSet.Count, nSamples, nSamples-newSet.Count, newSet.KInfo, newSet.AuxInfo);
        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
    end

    % Adds a dataset, or replaces the one with the same Label in place
    % (keeping its current show/hide state).
    function storeKennfeldSet(newSet)
        existingIdx = find(strcmp({app.KennfeldSets.Label}, newSet.Label), 1);
        if isempty(existingIdx)
            app.KennfeldSets(end+1) = newSet;
        else
            newSet.Visible = app.KennfeldSets(existingIdx).Visible;
            app.KennfeldSets(existingIdx) = newSet;
        end
    end

    % "Mehrere Messungen laden...": pick several trace files at once, tick
    % which ones to use in the settings popup, then parse + decode +
    % compute each one purely for the Kennfeld. Nothing is written to
    % app.Trace/app.Decoded, so the rest of the app (scrub tabs, CAN
    % output, ...) keeps showing whatever measurement was loaded before.
    % Traces are processed one at a time and dropped right after their
    % points are extracted, so memory stays at one decoded trace.
    function onKennfeldMultiLoadButton()
        filters = {'*.trc;*.txt', 'CAN trace files (*.trc, *.txt)'; ...
                   '*.trc', 'PCAN-View trace (*.trc)'; ...
                   '*.txt', 'SAMPlay log (*.txt)'};
        [files, folder] = uigetfile(filters, 'Messungen fürs Kennfeld auswählen', 'MultiSelect','on');
        if isequal(files, 0)
            return
        end
        files = cellstr(files);

        settings = showKennfeldSettingsDialog(sprintf( ...
            '%d Messungen ausgewählt. Haken setzen für alle, die ins Kennfeld sollen:', numel(files)), files);
        if ~settings.Proceed
            return
        end
        files = files(settings.Selected);
        if isempty(files)
            return
        end

        nFiles = numel(files);
        dlg = uiprogressdlg(app.UIFigure, 'Title','Kennfeld', 'Message','', ...
            'Cancelable','on', 'CancelText','Abbrechen');
        cleanupObj = onCleanup(@() close(dlg)); %#ok<NASGU>

        report = cell(nFiles, 1);
        nOk = 0;
        for k = 1:nFiles
            if dlg.CancelRequested
                report{k} = sprintf('%s: abgebrochen', files{k});
                continue
            end
            dlg.Value = (k-1) / nFiles;
            dlg.Message = sprintf('(%d/%d) %s: lese und dekodiere...', k, nFiles, files{k});
            drawnow;
            try
                trace = parseTraceFile(fullfile(folder, files{k}));
                if isempty(trace.Time)
                    report{k} = sprintf('%s: keine CAN-Frames gefunden', files{k});
                    continue
                end
                decoded = decodeMessages(trace, app.DBC);
                trace = []; %#ok<NASGU> -- free memory before the next file
                missing = kennfeldMissingKeys(decoded);
                if ~isempty(missing)
                    report{k} = sprintf('%s: Signale fehlen (%s)', files{k}, strjoin(missing, ', '));
                    continue
                end
                dlg.Message = sprintf('(%d/%d) %s: berechne Effizienzpunkte...', k, nFiles, files{k});
                drawnow;
                newSet = computeKennfeldSet(decoded, files{k}, settings);
                decoded = []; %#ok<NASGU>
                storeKennfeldSet(newSet);
                nOk = nOk + 1;
                report{k} = sprintf('%s: %d Punkte, %s', files{k}, newSet.Count, newSet.KInfo);
            catch ME
                report{k} = sprintf('%s: FEHLER -- %s', files{k}, ME.message);
            end
        end
        dlg.Value = 1;

        app.KennfeldStatusLabel.Text = sprintf('%d von %d Messungen hinzugefügt/aktualisiert. %s', ...
            nOk, nFiles, kennfeldFilterDesc(settings));
        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
        if nOk < nFiles
            uialert(app.UIFigure, strjoin(report, newline), 'Kennfeld: nicht alle Messungen übernommen', ...
                'Icon','warning');
        end
    end

    % Rebuilds the scrollable per-dataset row list from scratch -- cheap
    % (a handful of datasets at most) and simpler than diffing the old
    % rows against the new dataset array.
    function updateKennfeldDatasetPanel()
        panel = app.KennfeldDatasetPanel;
        delete(panel.Children);
        n = numel(app.KennfeldSets);
        if n == 0
            phGrid = uigridlayout(panel, [1 1], 'Padding',[8 8 8 8]);
            uilabel(phGrid, 'Text', ...
                'Noch keine Datensätze -- Messung laden und "Aus aktueller Messung berechnen..." drücken.', ...
                'FontColor',[0.55 0.55 0.55], 'WordWrap','on');
            return
        end
        % Scrollable on the grid itself: a uigridlayout always fills its
        % parent panel, so the panel's own Scrollable never kicks in and
        % rows past the panel height were simply cut off.
        rowsGrid = uigridlayout(panel, [n 1], 'RowHeight', repmat({30},1,n), 'RowSpacing',2, ...
            'Padding',[4 4 4 4], 'Scrollable','on');
        for i = 1:n
            row = uigridlayout(rowsGrid, [1 2], 'ColumnWidth', {'1x',90}, 'Padding',[0 0 0 0], 'ColumnSpacing',6);
            row.Layout.Row = i;
            s = app.KennfeldSets(i);
            uicheckbox(row, 'Text', sprintf('%s (%d Punkte, k = %.3f)', s.Label, s.Count, s.K), ...
                'Tooltip', strjoin({s.CurrInfo, s.KInfo, s.AuxInfo}, newline), ...
                'Value', s.Visible, ...
                'ValueChangedFcn', @(src,~) onKennfeldVisibilityToggled(i, src.Value));
            rmBtn = uibutton(row, 'push', 'Text','Entfernen', ...
                'ButtonPushedFcn', @(~,~) onKennfeldRemoveDataset(i));
            rmBtn.Layout.Column = 2;
        end
    end

    function onKennfeldVisibilityToggled(idx, val)
        if idx > numel(app.KennfeldSets)
            return
        end
        app.KennfeldSets(idx).Visible = val;
        refreshKennfeldPlot();
    end

    function onKennfeldRemoveDataset(idx)
        if idx > numel(app.KennfeldSets)
            return
        end
        app.KennfeldSets(idx) = [];
        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
    end

    function onKennfeldClearButton()
        app.KennfeldSets = emptyKennfeldSets();
        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
        app.KennfeldStatusLabel.Text = 'Noch keine Messung geladen.';
    end

    function onKennfeldSaveButton()
        if isempty(app.KennfeldSets)
            uialert(app.UIFigure, 'Kein Kennfeld zum Speichern vorhanden.', 'Nichts zu speichern');
            return
        end
        [file, folder] = uiputfile('*.mat', 'Kennfeld speichern', 'Kennfeld.mat');
        if isequal(file,0)
            return
        end
        kennfeldSets = app.KennfeldSets; %#ok<NASGU>
        save(fullfile(folder,file), 'kennfeldSets');
        app.KennfeldStatusLabel.Text = sprintf('Gespeichert: %s (%d Datensätze).', file, numel(app.KennfeldSets));
    end

    function onKennfeldLoadButton()
        [file, folder] = uigetfile('*.mat', 'Kennfeld laden');
        if isequal(file,0)
            return
        end
        try
            s = load(fullfile(folder,file), 'kennfeldSets');
            loaded = s.kennfeldSets;
        catch ME
            uialert(app.UIFigure, ['Konnte Datei nicht laden: ' ME.message], 'Fehler beim Laden');
            return
        end
        % Files saved before the visibility toggle was added lack this
        % field -- default those datasets to visible.
        if ~isempty(loaded) && ~isfield(loaded, 'Visible')
            [loaded.Visible] = deal(true);
        end
        % Files saved before the k/aux corrections existed were computed
        % the old way (0x186 current, no corrections) -- label them so.
        if ~isempty(loaded) && ~isfield(loaded, 'K')
            [loaded.K] = deal(1);
            [loaded.KInfo] = deal('k = 1 (alte Datei, ohne Korrekturen berechnet)');
            [loaded.AuxInfo] = deal('Grundlast: nicht abgezogen (alte Datei)');
            [loaded.CurrInfo] = deal('Strom: 0x186 (alte Datei)');
        end
        loaded = orderfields(loaded, emptyKennfeldSets());
        for i = 1:numel(loaded)
            existingIdx = find(strcmp({app.KennfeldSets.Label}, loaded(i).Label), 1);
            if isempty(existingIdx)
                app.KennfeldSets(end+1) = loaded(i);
            else
                app.KennfeldSets(existingIdx) = loaded(i);
            end
        end
        updateKennfeldDatasetPanel();
        refreshKennfeldPlot();
        app.KennfeldStatusLabel.Text = sprintf('Geladen: %s (%d Datensätze hinzugefügt/aktualisiert).', file, numel(loaded));
    end

    function onKennfeldScaleButton()
        visibleSets = app.KennfeldSets(logical([app.KennfeldSets.Visible]));
        if isempty(visibleSets)
            return
        end
        N = vertcat(visibleSets.N);
        T = vertcat(visibleSets.T);
        nMax = max(N, [], 'omitnan');
        tMax = max(T, [], 'omitnan');
        if ~isfinite(nMax) || nMax <= 0
            nMax = 1;
        end
        if ~isfinite(tMax) || tMax <= 0
            tMax = 1;
        end
        app.KennfeldAxes.XLim = [0 nMax];
        app.KennfeldAxes.YLim = [0 tMax];
    end

    % Opens a separate, non-modal 3D popup showing the currently visible
    % raw points gridded onto a Drehzahl x Moment mesh and averaged per
    % cell (binKennfeldPoints), rendered as a connected surf() -- the
    % "form surfaces out of nearby points" step the raw 2D scatter
    % deliberately does not do. Non-modal (no uiwait) since it's a pure
    % viewer with no result the caller needs back: the user can keep
    % working in the main window, rotate/zoom it freely, and even open it
    % again with different bin widths for comparison.
    function onKennfeld3DButton()
        visibleSets = app.KennfeldSets(logical([app.KennfeldSets.Visible]));
        if isempty(visibleSets)
            uialert(app.UIFigure, ...
                'Keine sichtbaren Kennfeld-Datenpunkte vorhanden -- zuerst berechnen und/oder einblenden.', ...
                'Keine Daten');
            return
        end
        N   = vertcat(visibleSets.N);
        T   = vertcat(visibleSets.T);
        Eta = vertcat(visibleSets.Eta);
        showKennfeld3DPopup(N, T, Eta);
    end

    function showKennfeld3DPopup(N, T, Eta)
        % Cell averaging only makes sense over physically sane efficiency
        % values -- a handful of division-by-near-zero-battery-power
        % outliers (see minBattPowerW in onKennfeldCalcButton) would
        % otherwise dominate a cell's MEAN far more than they visually
        % dominate the 2D scatter (which only clips their color, never
        % touches the underlying numbers). The raw scatter tab keeps
        % showing everything unfiltered; this is specific to the averaged
        % surface, where an unfiltered outlier would fabricate a bogus
        % spike/pit instead of a genuine trend. The "unrealistische Werte
        % einblenden" checkbox switches this filter off on demand (only
        % non-finite values stay excluded, they can't be plotted at all).
        finiteMask = isfinite(Eta) & isfinite(N) & isfinite(T);
        NAll = N(finiteMask); TAll = T(finiteMask); EtaAll = Eta(finiteMask);
        realistic = EtaAll >= 0 & EtaAll <= 1;
        nUnrealistic = sum(~realistic);

        % Default raster derived from the realistic points only, so a few
        % extreme outliers don't blow up the cell size once they're shown.
        if any(realistic)
            nRange = max(NAll(realistic)) - min(NAll(realistic));
            tRange = max(TAll(realistic)) - min(TAll(realistic));
        else
            nRange = max(NAll) - min(NAll);
            tRange = max(TAll) - min(TAll);
        end
        if isempty(nRange) || ~(nRange > 0); nRange = 1; end
        if isempty(tRange) || ~(tRange > 0); tRange = 1; end
        defaultBinN = nRange / 30;
        defaultBinT = tRange / 30;

        mainPos = app.UIFigure.Position;
        popW = 920; popH = 620;
        popPos = [mainPos(1)+(mainPos(3)-popW)/2, mainPos(2)+(mainPos(4)-popH)/2, popW, popH];
        pf = uifigure('Name','Kennfeldfläche (3D)', 'Position', popPos);

        pg = uigridlayout(pf, [3 1], 'RowHeight', {40,40,'1x'}, 'RowSpacing',4, 'Padding',[12 12 12 12]);

        labelRow = uigridlayout(pg, [1 4], 'ColumnWidth', {180,180,160,'1x'}, 'Padding',[0 0 0 0], 'ColumnSpacing',10);
        labelRow.Layout.Row = 1;
        uilabel(labelRow, 'Text','Rasterbreite Drehzahl (rpm)');
        uilabel(labelRow, 'Text','Rasterbreite Moment (Nm)');
        uilabel(labelRow, 'Text','Min. Punkte / Zelle');
        unrealCheck = uicheckbox(labelRow, 'Value', false, ...
            'Text', sprintf('Unrealistische Werte einblenden (<0 / >100 %%, %d Punkte)', nUnrealistic), ...
            'Tooltip','Punkte mit Wirkungsgrad außerhalb 0-100 % (z. B. Rekuperation, Division durch ~0 W Batterieleistung) mitteln', ...
            'ValueChangedFcn', @(~,~) redraw());

        fieldRow = uigridlayout(pg, [1 5], 'ColumnWidth', {180,180,160,190,140}, 'Padding',[0 0 0 0], 'ColumnSpacing',10);
        fieldRow.Layout.Row = 2;
        binNField = uieditfield(fieldRow, 'numeric', 'Value', defaultBinN, 'Limits',[1e-6 Inf]);
        binTField = uieditfield(fieldRow, 'numeric', 'Value', defaultBinT, 'Limits',[1e-6 Inf]);
        minPtsField = uieditfield(fieldRow, 'numeric', 'Value', 1, 'Limits',[1 Inf], 'RoundFractionalValues','on');
        rawCheck = uicheckbox(fieldRow, 'Text','Rohpunkte einblenden', 'Value', false, ...
            'ValueChangedFcn', @(~,~) redraw());
        uibutton(fieldRow, 'push', 'Text','Aktualisieren', 'ButtonPushedFcn', @(~,~) redraw());

        ax3 = uiaxes(pg);
        ax3.Layout.Row = 3;
        view(ax3, -37.5, 30);

        redraw();

        function redraw()
            binN = binNField.Value;
            binT = binTField.Value;
            minPts = round(minPtsField.Value);
            if unrealCheck.Value
                use = true(size(EtaAll));
            else
                use = realistic;
            end
            N = NAll(use); T = TAll(use); Eta = EtaAll(use);
            [Xc, Yc, Zc] = binKennfeldPoints(N, T, Eta, binN, binT, minPts);

            cla(ax3);
            nFilled = sum(~isnan(Zc(:)));
            if isempty(Xc) || nFilled == 0
                text(ax3, 0.5, 0.5, 0.5, 'Keine Zelle mit ausreichend Punkten -- Rasterbreite verkleinern oder Min.-Punkte verringern.', ...
                    'Units','normalized', 'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
            else
                % Every filled cell is one quad on a shared corner grid:
                % each corner's height is the mean of all filled cells
                % touching it (kennfeldCornerHeights), so adjacent cells
                % meet at common corners and form one connected surface,
                % while an isolated cell gets its own mean at all 4
                % corners (a flat tile). A plain surf() over cell centers
                % would instead need all 4 surrounding cells filled to
                % draw anything, so isolated cells would vanish.
                Zk = kennfeldCornerHeights(Zc);
                [nT, nN] = size(Zc);
                cornerN = Xc(1,1) - binN/2 + (0:nN) * binN;
                cornerT = Yc(1,1) - binT/2 + (0:nT)' * binT;
                [XK, YK] = meshgrid(cornerN, cornerT);
                verts = [XK(:), YK(:), Zk(:)];
                [ci, cj] = find(~isnan(Zc));
                cornerIdx = @(i, j) sub2ind([nT+1, nN+1], i, j);
                faces = [cornerIdx(ci, cj), cornerIdx(ci, cj+1), cornerIdx(ci+1, cj+1), cornerIdx(ci+1, cj)];
                patch(ax3, 'Faces',faces, 'Vertices',verts, 'FaceVertexCData',Zk(:), ...
                    'FaceColor','interp', 'EdgeColor',[0.3 0.3 0.3], 'EdgeAlpha',0.25);
                hold(ax3, 'on');
                if rawCheck.Value
                    scatter3(ax3, N, T, Eta*100, 6, [0.15 0.15 0.15], 'filled', 'MarkerFaceAlpha',0.25);
                end
                hold(ax3, 'off');
            end
            cb = colorbar(ax3);
            cb.Label.String = 'Gesamtwirkungsgrad (%)';
            applyKennfeldColors(ax3, cb);
            xlabel(ax3, 'Drehzahl (rpm)');
            ylabel(ax3, 'Moment (Nm)');
            zlabel(ax3, 'Gesamtwirkungsgrad (%)');
            grid(ax3, 'on');
            dropNote = '';
            if nUnrealistic > 0 && unrealCheck.Value
                dropNote = sprintf(' (inkl. %d Punkte außerhalb 0-100%%)', nUnrealistic);
            elseif nUnrealistic > 0
                dropNote = sprintf(' (%d Punkte außerhalb 0-100%% ausgeschlossen)', nUnrealistic);
            end
            title(ax3, sprintf('%d von %d Zellen belegt -- Raster %.3g rpm x %.3g Nm%s', ...
                nFilled, numel(Zc), binN, binT, dropNote));
        end
    end

    function refreshKennfeldPlot()
        ax = app.KennfeldAxes;
        cla(ax);
        xlabel(ax, 'Drehzahl (rpm)');
        ylabel(ax, 'Drehmoment (Nm)');
        if isempty(app.KennfeldSets)
            title(ax, 'Effizienz-Kennfeld (Gesamtwirkungsgrad)');
            text(ax, 0.5, 0.5, ...
                'Noch keine Kennfeld-Daten -- Messung laden und "Aus aktueller Messung berechnen..." drücken.', ...
                'Units','normalized', 'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
            return
        end
        visibleSets = app.KennfeldSets(logical([app.KennfeldSets.Visible]));
        if isempty(visibleSets)
            title(ax, 'Effizienz-Kennfeld (Gesamtwirkungsgrad)');
            text(ax, 0.5, 0.5, 'Alle Datensätze ausgeblendet.', ...
                'Units','normalized', 'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
            return
        end
        N   = vertcat(visibleSets.N);
        T   = vertcat(visibleSets.T);
        Eta = vertcat(visibleSets.Eta);

        % Quadrant reference lines first (drawn under the points) -- N=0/
        % T=0 separate forward/reverse and motoring/regen at a glance.
        xline(ax, 0, 'Color',[0.5 0.5 0.5], 'LineStyle',':');
        yline(ax, 0, 'Color',[0.5 0.5 0.5], 'LineStyle',':');

        % Shrink markers and add a little transparency as the point count
        % grows -- keeps dense, frequently-visited operating points
        % readable as overlapping-but-distinguishable dots instead of one
        % solid blob, without needing any binning/averaging yet.
        nPts = numel(N);
        if nPts > 20000
            markerSize = 4;
        elseif nPts > 5000
            markerSize = 6;
        else
            markerSize = 10;
        end
        sc = scatter(ax, N, T, markerSize, Eta*100, 'filled');
        sc.MarkerFaceAlpha = 0.55;
        cb = colorbar(ax);
        cb.Label.String = 'Gesamtwirkungsgrad (%)';
        applyKennfeldColors(ax, cb);
        grid(ax, 'on');
        title(ax, sprintf('Effizienz-Kennfeld (%d Punkte, %d von %d Messungen sichtbar)', ...
            nPts, numel(visibleSets), numel(app.KennfeldSets)));
    end

    % ------------------------------------------------------------------
    % Cell internal resistance ("Zell-Innenwiderstand") tab: estimates each
    % of the 36 cells' effective internal resistance from its voltage drop
    % under load. The actual math lives in the plain helper
    % computeCellResistance (bottom of this file) so it can be tested
    % headlessly; this block is only UI + wiring.
    %
    % Method, in short (details + the data findings behind each choice in
    % PROJECT_NOTES.md):
    %   - Cell voltages arrive multiplexed on 0x406, one cell per 100 ms
    %     frame, 37 slots per cycle (slot 37 is a 0 mV filler) -> each cell
    %     is refreshed every ~3.7 s.
    %   - Current comes from 0x386 (BMS_Dynamic_Current_Limits, 10 Hz), not
    %     0x186 (only 1 Hz).
    %   - The cell voltages lag the current by ~1 s (same for all cells,
    %     measured by cross-correlation), so the current is sampled at
    %     t_cell - lag, not "the newest value" -- lag auto-estimated by
    %     default.
    %   - R = slope of dV vs dI between two CONSECUTIVE readings of the same
    %     cell (~3.7 s apart), fitted through the origin -- differencing
    %     cancels the unknown and SoC-drifting open-circuit voltage, which a
    %     plain V/I ratio can't.
    %   - Startup garbage (0 mV cells, -1300 A current) is plausibility-
    %     filtered and the fit is outlier-robust (MAD rejection) -- a single
    %     such frame otherwise tripled some cells' result.
    function buildCellResistanceTabContent(tab)
        tg = uigridlayout(tab, [3 1], 'RowHeight', {32,58,'1x'}, 'RowSpacing',6, 'Padding',[10 10 10 10]);

        ctl = uigridlayout(tg, [1 15], 'ColumnWidth', ...
            {120, 80, 48, 58, 76, 48, 72, 48, 86, 48, 180, 44, 115, '1x', 100}, ...
            'Padding',[0 0 0 0], 'ColumnSpacing',6);
        ctl.Layout.Row = 1;
        uibutton(ctl, 'push', 'Text','Berechnen', 'FontWeight','bold', ...
            'Tooltip','Innenwiderstand aller 36 Zellen aus der geladenen Messung schätzen', ...
            'ButtonPushedFcn', @(~,~) onCellResCalc());
        app.CellResAutoLag = uicheckbox(ctl, 'Text','Auto-Lag', 'Value',true, ...
            'Tooltip','Verzögerung Spannung ggü. Strom automatisch per Kreuzkorrelation bestimmen', ...
            'ValueChangedFcn', @(src,~) onCellResAutoLagChanged(src.Value));
        uilabel(ctl, 'Text','Lag (s)', 'HorizontalAlignment','right');
        app.CellResLagField = uieditfield(ctl, 'numeric', 'Value',1.0, 'Limits',[-2 5], 'Enable','off', ...
            'Tooltip','Strom wird zum Zeitpunkt t_Zelle - Lag abgetastet');
        uilabel(ctl, 'Text','Min |ΔI| (A)', 'HorizontalAlignment','right');
        app.CellResMinDIField = uieditfield(ctl, 'numeric', 'Value',5, 'Limits',[0 500], ...
            'Tooltip','Nur Messpaare mit mindestens dieser Stromänderung gehen in den Fit ein');
        uilabel(ctl, 'Text','Max Δt (s)', 'HorizontalAlignment','right');
        app.CellResMaxDTField = uieditfield(ctl, 'numeric', 'Value',5, 'Limits',[0.5 60], ...
            'Tooltip','Zwei Werte derselben Zelle werden nur gepaart, wenn sie höchstens so weit auseinander liegen (normal: 3,7 s)');
        uilabel(ctl, 'Text','Schwelle (%)', 'HorizontalAlignment','right');
        app.CellResThreshField = uieditfield(ctl, 'numeric', 'Value',15, 'Limits',[1 500], ...
            'Tooltip','Abweichung vom Median aller Zellen, ab der eine Zelle als auffällig markiert wird');
        app.CellResRangeCheck = uicheckbox(ctl, 'Text','Nur sichtbarer Zeitbereich', 'Value',false, ...
            'Tooltip','Nur den über die View-Schieberegler gewählten Zeitbereich auswerten');
        app.CellResRangeCheck.Layout.Column = 11;
        uilabel(ctl, 'Text','Strom', 'HorizontalAlignment','right');
        app.CellResSourceDropdown = uidropdown(ctl, 'Items',{'Auto','0x386 (10 Hz)','0x186 (1 Hz)'}, ...
            'ItemsData',{'auto','0x386','0x186'}, 'Value','auto', ...
            'Tooltip',['Stromquelle. Auto = 0x386, außer 0x186 korreliert deutlich besser mit den ' ...
            'Zellspannungen (neues BMS/PEAK-Logs: 0x386 etwas besser; Original-BMS/SAMPlay: beide ähnlich).']);
        exportBtn = uibutton(ctl, 'push', 'Text','CSV-Export...', ...
            'ButtonPushedFcn', @(~,~) onCellResExport());
        exportBtn.Layout.Column = 15;

        app.CellResStatusLabel = uilabel(tg, 'Text','', 'FontSize',11.5, 'WordWrap','on', ...
            'VerticalAlignment','top');
        app.CellResStatusLabel.Layout.Row = 2;

        body = uigridlayout(tg, [1 2], 'ColumnWidth', {600,'1x'}, 'Padding',[0 0 0 0], 'ColumnSpacing',8);
        body.Layout.Row = 3;

        app.CellResTable = uitable(body, 'ColumnSortable',true, 'RowName',{}, ...
            'SelectionType','row', 'Multiselect','off', ...
            'SelectionChangedFcn', @(src,~) onCellResTableSelect(src));
        app.CellResTable.Layout.Column = 1;

        plots = uigridlayout(body, [2 2], 'RowHeight', {'1x','1x'}, 'ColumnWidth', {'1.3x','1x'}, ...
            'Padding',[0 0 0 0], 'RowSpacing',6, 'ColumnSpacing',6);
        plots.Layout.Column = 2;
        app.CellResBarAxes = uiaxes(plots);
        app.CellResBarAxes.Layout.Row = 1;
        app.CellResBarAxes.Layout.Column = [1 2];
        app.CellResScatterAxes = uiaxes(plots);
        app.CellResScatterAxes.Layout.Row = 2;
        app.CellResScatterAxes.Layout.Column = 1;
        app.CellResLagAxes = uiaxes(plots);
        app.CellResLagAxes.Layout.Row = 2;
        app.CellResLagAxes.Layout.Column = 2;

        refreshCellResResults();
    end

    % Nested (not anonymous) so it sees the current app struct -- an
    % anonymous fcn would capture app before CellResLagField exists.
    function onCellResAutoLagChanged(isAuto)
        app.CellResLagField.Enable = matlab.lang.OnOffSwitchState(~isAuto);
    end

    function opts = cellResOptions()
        opts = struct();
        if app.CellResAutoLag.Value
            opts.Lag = NaN;
        else
            opts.Lag = app.CellResLagField.Value;
        end
        opts.MinDI     = app.CellResMinDIField.Value;
        opts.MaxDT     = app.CellResMaxDTField.Value;
        opts.Threshold = app.CellResThreshField.Value;
        opts.CurrentSource = app.CellResSourceDropdown.Value;
        if app.CellResRangeCheck.Value
            opts.TRange = app.ViewRange;
        else
            opts.TRange = [-Inf Inf];
        end
    end

    function onCellResCalc()
        if isempty(app.Trace)
            uialert(app.UIFigure, 'Bitte zuerst eine Messung (.trc/.txt) laden.', 'Keine Messung geladen');
            return
        end
        dlg = uiprogressdlg(app.UIFigure, 'Title','Zell-Innenwiderstand', ...
            'Message','Werte Spannungsabfall unter Last aus...', 'Indeterminate','on');
        cleanupObj = onCleanup(@() close(dlg)); %#ok<NASGU>
        try
            res = computeCellResistance(app.Decoded, cellResOptions());
        catch ME
            uialert(app.UIFigure, ME.message, 'Berechnung fehlgeschlagen');
            return
        end
        app.CellRes = res;
        if ~app.CellResAutoLag.Value
            % keep the field as entered
        elseif isfinite(res.Lag)
            app.CellResLagField.Value = res.Lag;
        end
        [~, worst] = max(res.R);
        if isfinite(res.R(worst))
            app.CellResSelected = worst;
        end
        refreshCellResResults();
    end

    function refreshCellResResults()
        res = app.CellRes;
        axB = app.CellResBarAxes;
        axS = app.CellResScatterAxes;
        axL = app.CellResLagAxes;
        cla(axB); cla(axS); cla(axL);
        legend(axS, 'off');

        colNames = {'Zelle','R (mΩ)','±95% (mΩ)','Abw. (%)','R²','Paare','Ø U (mV)','Min U (mV)','Bewertung'};
        if isempty(res)
            app.CellResTable.Data = table();
            app.CellResTable.ColumnName = colNames;
            removeStyle(app.CellResTable);
            if isempty(app.Trace)
                app.CellResStatusLabel.Text = 'Noch keine Messung geladen.';
            else
                app.CellResStatusLabel.Text = ['Messung geladen -- "Berechnen" drücken. Methode: ΔU/ΔI zwischen zwei ' ...
                    'aufeinanderfolgenden Werten derselben Zelle (~3,7 s Abstand), Strom aus 0x386 (10 Hz), ' ...
                    'um die Messverzögerung der Zellspannung zurückversetzt.'];
            end
            for ax = [axB axS axL]
                text(ax, 0.5, 0.5, 'Noch nicht berechnet', 'Units','normalized', ...
                    'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
            end
            title(axB, 'Innenwiderstand je Zelle');
            title(axS, 'ΔU über ΔI');
            title(axL, 'Lag-Suche');
            return
        end

        % ---- table ----
        cellNo = (1:36)';
        T = table(cellNo, round(res.R,3), round(res.CI95,3), round(res.DevPct,1), round(res.R2,3), ...
            res.NPairs, round(res.Vmean), res.Vmin, res.Status, 'VariableNames', ...
            {'Zelle','R','CI','Dev','R2','Paare','Vmean','Vmin','Bewertung'});
        app.CellResTable.Data = T;
        app.CellResTable.ColumnName = colNames;
        app.CellResTable.ColumnWidth = {46,64,80,66,50,50,70,78,'auto'};
        removeStyle(app.CellResTable);
        styleRows(res.StatusCode == 3, [1.00 0.80 0.80]);
        styleRows(res.StatusCode == 2, [1.00 0.93 0.75]);
        styleRows(res.StatusCode == 4, [0.82 0.90 1.00]);
        styleRows(res.StatusCode == 0, [0.90 0.90 0.90]);

        % ---- bar chart: deviation from the cell median (%), with 95% CI and
        % the +-threshold band. Plotted as a deviation rather than absolute
        % mOhm because the cells typically differ by only a few percent --
        % on a 0-based absolute axis all 36 bars look identical. Absolute
        % values are in the table.
        dev = res.DevPct(:)';
        ciPct = 100 * res.CI95(:)' / res.Median;
        thr = res.Threshold;
        b = bar(axB, 1:36, dev, 'FaceColor','flat', 'EdgeColor','none');
        b.CData = cellResStatusColors(res.StatusCode);
        b.ButtonDownFcn = @(~,evt) onCellResBarClick(evt);
        hold(axB, 'on');
        yregion(axB, -thr, thr, 'FaceColor',[0.5 0.5 0.5], 'FaceAlpha',0.08, 'HitTest','off');
        errorbar(axB, 1:36, dev, ciPct, 'k', 'LineStyle','none', 'CapSize',3, ...
            'HitTest','off', 'PickableParts','none');
        yline(axB, [-thr thr], '--', 'Color',[0.8 0.15 0.15], 'HitTest','off');
        sel = app.CellResSelected;
        if isfinite(dev(sel))
            xline(axB, sel, ':', 'Color',[0 0 0], 'LineWidth',1.2, 'HitTest','off');
        end
        lim = max([abs(dev) + ciPct, thr], [], 'omitnan') * 1.15;
        bmsHigh = res.Bms.CellHigh;
        if isfinite(bmsHigh) && res.Bms.CellLow ~= bmsHigh && isfinite(lim)
            text(axB, bmsHigh, lim*0.93, 'BMS max', 'HorizontalAlignment','center', ...
                'FontSize',8, 'FontWeight','bold', 'Color',[0.8 0.15 0.15], 'HitTest','off');
        end
        hold(axB, 'off');
        axB.XLim = [0.3 36.7];
        axB.XTick = 1:36;
        axB.FontSize = 9;
        if isfinite(lim) && lim > 0
            axB.YLim = [-lim lim];
        end
        xlabel(axB, 'Zelle (Balken anklicken = Details)');
        ylabel(axB, 'Abw. vom Median (%)');
        grid(axB, 'on');
        title(axB, sprintf('Median %.3f mΩ/Zelle · Summe %.1f mΩ · Streuung (Std) %.1f %% · Schwelle ±%g %%', ...
            res.Median, sum(res.R,'omitnan'), 100*std(res.R,'omitnan')/res.Median, thr), 'FontSize',10);

        drawCellResScatter();

        % ---- lag scan ----
        if ~isempty(res.LagScan.Lag)
            hold(axL, 'on');
            for si = 1:numel(res.LagScan.Corr)
                isPick = si == res.LagScan.Picked;
                plot(axL, res.LagScan.Lag, res.LagScan.Corr{si}, 'Color', defaultLineColor(si), ...
                    'LineWidth', 0.8 + 1.0*isPick, 'DisplayName', res.LagScan.Name{si});
            end
            xline(axL, res.Lag, 'r-', sprintf('%.2f s', res.Lag), 'LabelVerticalAlignment','bottom', ...
                'HandleVisibility','off');
            hold(axL, 'off');
            legend(axL, 'Location','south', 'FontSize',8);
            grid(axL, 'on');
            xlabel(axL, 'Lag Strom → Spannung (s)');
            ylabel(axL, 'Korrelation ΔU/ΔI');
            if res.LagAuto
                title(axL, 'Lag-Suche (automatisch)');
            else
                title(axL, 'Lag-Suche (manueller Lag)');
            end
        end

        % ---- summary text ----
        nAuff = sum(res.StatusCode == 3);
        if all(isnan(res.R))
            verdict = ['Keine auswertbaren Laständerungen (z.B. Ladevorgang mit konstantem Strom) -- ' ...
                'Fahrt-Messung verwenden oder Min |ΔI| verringern.'];
        elseif nAuff == 0
            verdict = 'Keine Zelle über der Schwelle.';
        else
            verdict = sprintf('Auffällig: Zelle %s.', strjoin(arrayfun(@num2str, find(res.StatusCode == 3)', 'UniformOutput',false), ', '));
        end
        if res.TRange(1) > -Inf
            rangeTxt = sprintf(', Zeitbereich %.0f-%.0f s', res.TRange(1), res.TRange(2));
        else
            rangeTxt = '';
        end
        if all(isnan(res.Temp))
            tempTxt = 'Zelltemperatur: n/a.';
        elseif res.Temp(1) == res.Temp(3)
            tempTxt = sprintf('Zelltemperatur: konstant %g °C (vermutl. Platzhalter).', res.Temp(2));
        else
            tempTxt = sprintf('Zelltemperatur: %g…%g °C (Median %g).', res.Temp(1), res.Temp(3), res.Temp(2));
        end
        app.CellResStatusLabel.Text = sprintf([ ...
            '%s   Median %.3f mΩ/Zelle, Lag %.2f s (Korrelation %.3f), Strom: %s%s, %d Paare gesamt.\n' ...
            'BMS-eigene Werte (0x306, vermutl. mΩ): %s   %s   ' ...
            'Effektiver Widerstand im Sekundenbereich, temperatur-/SoC-abhängig -- Zellen vergleichen, nicht Absolutwerte zwischen Fahrten.'], ...
            verdict, res.Median, res.Lag, res.LagCorr, res.CurrentSource, rangeTxt, sum(res.NPairs), ...
            bmsResistanceSummary(res.Bms), tempTxt);

        function styleRows(mask, col)
            rows = find(mask);
            if ~isempty(rows)
                addStyle(app.CellResTable, uistyle('BackgroundColor', col, 'FontColor', [0 0 0]), 'row', rows);
            end
        end
    end

    function s = bmsResistanceSummary(bms)
        if all(isnan([bms.Low bms.Avg bms.High]))
            s = 'nicht in dieser Messung.';
        elseif bms.CellLow == bms.CellHigh
            s = sprintf('min/Ø/max %.1f/%.1f/%.1f, Zelle %d als beste UND schlechteste (Platzhalter-Werte).', ...
                bms.Low, bms.Avg, bms.High, bms.CellLow);
        else
            s = sprintf('min %.1f (meist Zelle %d), Ø %.1f, max %.1f (meist Zelle %d, %.0f %% der Zeit).', ...
                bms.Low, bms.CellLow, bms.Avg, bms.High, bms.CellHigh, bms.CellHighShare);
        end
    end

    function drawCellResScatter()
        res = app.CellRes;
        ax = app.CellResScatterAxes;
        cla(ax);
        if isempty(res)
            return
        end
        k = app.CellResSelected;
        p = res.Pairs{k};
        hold(ax, 'on');
        if isempty(p.dI)
            text(ax, 0.5, 0.5, sprintf('Zelle %d: keine Messpaare', k), 'Units','normalized', ...
                'HorizontalAlignment','center', 'Color',[0.55 0.55 0.55]);
        else
            rej = ~p.Used;
            scatter(ax, p.dI(p.Used), p.dV(p.Used), 12, [0 0.447 0.741], 'filled', ...
                'MarkerFaceAlpha',0.5, 'DisplayName','verwendet');
            if any(rej)
                scatter(ax, p.dI(rej), p.dV(rej), 14, [0.6 0.6 0.6], 'x', 'DisplayName','verworfen');
            end
            xr = [min(p.dI) max(p.dI)];
            plot(ax, xr, res.R(k)*xr, 'r-', 'LineWidth',1.5, 'DisplayName', sprintf('Zelle %d: %.3f mΩ', k, res.R(k)));
            plot(ax, xr, res.Median*xr, '--', 'Color',[0.3 0.3 0.3], 'LineWidth',1, ...
                'DisplayName', sprintf('Median: %.3f mΩ', res.Median));
            legend(ax, 'Location','northwest', 'FontSize',8);
        end
        hold(ax, 'off');
        grid(ax, 'on');
        ax.FontSize = 9;
        xlabel(ax, 'ΔI (A)');
        ylabel(ax, 'ΔU (mV)');
        title(ax, sprintf('Zelle %d -- %s', k, res.Status{k}));
    end

    function selectCellRes(k)
        if isempty(app.CellRes) || k < 1 || k > 36
            return
        end
        app.CellResSelected = k;
        refreshCellResResults();
    end

    function onCellResTableSelect(src)
        sel = src.Selection;
        if isempty(sel) || isempty(src.Data) || height(src.Data) == 0
            return
        end
        % Selection indexes the (unsorted) Data, whose first column is the
        % cell number -- read it from there so column sorting can't mix up
        % which cell was clicked.
        selectCellRes(src.Data.Zelle(sel(1)));
    end

    function onCellResBarClick(evt)
        k = round(evt.IntersectionPoint(1));
        selectCellRes(k);
    end

    function onCellResExport()
        if isempty(app.CellRes)
            uialert(app.UIFigure, 'Noch keine Ergebnisse -- zuerst "Berechnen".', 'Nichts zu exportieren');
            return
        end
        [~, base] = fileparts(app.CurrentTraceLabel);
        [file, folder] = uiputfile('*.csv', 'Innenwiderstand exportieren', [base '_Innenwiderstand.csv']);
        if isequal(file,0)
            return
        end
        res = app.CellRes;
        T = table((1:36)', res.R, res.CI95, res.DevPct, res.R2, res.NPairs, res.Vmean, res.Vmin, res.Status, ...
            'VariableNames', {'Zelle','R_mOhm','CI95_mOhm','Abw_Median_Pct','R2','Paare','U_mittel_mV','U_min_mV','Bewertung'});
        writetable(T, fullfile(folder,file), 'Delimiter',';');
        app.CellResStatusLabel.Text = sprintf('Exportiert: %s', fullfile(folder,file));
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
        if app.IsPlaying
            stopPlayback();
        end
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
            app.CurrentTraceLabel = [nameOnly ext];

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
            app.PlayPauseButton.Enable = 'on';
            app.StepBackButton.Enable = 'on';
            app.StepForwardButton.Enable = 'on';

            % A new trace means a new frame sequence -- don't let an old
            % file's cursor position leak into this one's TX bookkeeping.
            app.LastTxTime = 0;
            app.CanFramesSent = 0;
            app.CanStatsLabel.Text = 'Gesendet: 0';
            app.CanLastFrameLabel.Text = 'Letzter Frame: --';

            % Resistance results belong to the previous trace.
            app.CellRes = [];
            refreshCellResResults();

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
        if app.IsPlaying
            stopPlayback();
        end
        updateAtTime(val);
        % A manual seek never transmits, but still moves the "already
        % sent up to" pointer -- otherwise the next Play would burst-send
        % every frame skipped over by the drag.
        app.LastTxTime = val;
    end

    % ------------------------------------------------------------------
    % Playback: a timer ticks at a fixed wall-clock rate; each tick derives
    % the trace time from actual elapsed wall time since play started
    % (tic/toc), not from a fixed step-per-tick, so real-time speed holds
    % regardless of UI/rendering jitter between ticks.
    function ensurePlayTimer()
        if isempty(app.PlayTimer) || ~isvalid(app.PlayTimer)
            app.PlayTimer = timer('ExecutionMode','fixedSpacing', 'Period',0.05, ...
                'TimerFcn', @(~,~) onPlayTick());
        end
    end

    function startPlayback()
        if isempty(app.Trace) || app.IsPlaying
            return
        end
        ensurePlayTimer();
        curT = app.TimelineSlider.Value;
        hiLimit = app.TimelineSlider.Limits(2);
        if curT >= hiLimit - 1e-9
            curT = app.TimelineSlider.Limits(1);
            app.TimelineSlider.Value = curT;
            updateAtTime(curT);
        end
        app.PlayStartTraceTime = curT;
        app.PlayStartTic = tic;
        % Start transmitting from the current cursor position, not from
        % wherever a stale LastTxTime happens to be (e.g. after a manual
        % seek far away) -- avoids a burst-replay of skipped-over frames.
        app.LastTxTime = curT;
        app.IsPlaying = true;
        app.PlayPauseButton.Text = char(9208);
        start(app.PlayTimer);
    end

    function stopPlayback()
        if ~isempty(app.PlayTimer) && isvalid(app.PlayTimer) && strcmp(app.PlayTimer.Running,'on')
            stop(app.PlayTimer);
        end
        app.IsPlaying = false;
        if isgraphics(app.PlayPauseButton)
            app.PlayPauseButton.Text = char(9654);
        end
    end

    function onPlayPause()
        if isempty(app.Trace)
            return
        end
        if app.IsPlaying
            stopPlayback();
        else
            startPlayback();
        end
    end

    function onPlayTick()
        if isempty(app.Trace)
            stopPlayback();
            return
        end
        newT = app.PlayStartTraceTime + toc(app.PlayStartTic);
        hiLimit = app.TimelineSlider.Limits(2);
        if newT >= hiLimit
            app.TimelineSlider.Value = hiLimit;
            updateAtTime(hiLimit);
            txFramesInRange(app.LastTxTime, hiLimit);
            app.LastTxTime = hiLimit;
            stopPlayback();
            return
        end
        app.TimelineSlider.Value = newT;
        updateAtTime(newT);
        txFramesInRange(app.LastTxTime, newT);
        app.LastTxTime = newT;
    end

    function onCloseRequest(src)
        if ~isempty(app.PlayTimer) && isvalid(app.PlayTimer)
            stop(app.PlayTimer);
            delete(app.PlayTimer);
        end
        try
            if ~isempty(app.CanChannel) && isvalid(app.CanChannel)
                stop(app.CanChannel);
                delete(app.CanChannel);
            end
        catch
        end
        delete(src);
    end

    % ------------------------------------------------------------------
    % Step exactly one CAN message forward/backward, i.e. jump the cursor
    % to the next/previous frame's own timestamp in app.Trace.Time, not a
    % fixed time increment.
    function stepFrame(dir)
        if isempty(app.Trace)
            return
        end
        if app.IsPlaying
            stopPlayback();
        end
        times = app.Trace.Time;
        cur = app.TimelineSlider.Value;
        tol = max(abs(cur), 1) * 1e-9;
        rowIdx = [];
        if dir > 0
            idx = find(times > cur + tol, 1, 'first');
            if isempty(idx)
                newT = app.TimelineSlider.Limits(2);
            else
                newT = times(idx);
                rowIdx = idx;
            end
        else
            idx = find(times < cur - tol, 1, 'last');
            if isempty(idx)
                newT = app.TimelineSlider.Limits(1);
            else
                newT = times(idx);
                rowIdx = idx;
            end
        end
        newT = min(max(newT, app.TimelineSlider.Limits(1)), app.TimelineSlider.Limits(2));
        app.TimelineSlider.Value = newT;
        updateAtTime(newT);
        % Step = exactly one CAN message, forward or backward -- send the
        % single frame landed on rather than a range (a "step back" isn't
        % a real-time replay, it's "show me this one message again").
        if ~isempty(rowIdx)
            sendFrameIndices(rowIdx);
        end
        app.LastTxTime = newT;
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
        app.LastTxTime = cVal;
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
trace = sanitizeTraceOrder(trace);
end

function trace = sanitizeTraceOrder(trace)
% The SAMPlay logger sometimes appends a few stale frames at the very end
% of a file whose timestamps jump back in time (LOG_C009/LOG_C011 in
% SAMPlay_Logs/Durs: last 2-3 rows ~18 s earlier, exact copies of frames
% already logged). That leaves a per-signal Time vector that is unsorted
% and contains a repeated timestamp, and interp1 in sampleAtTime then
% throws "Sample points must be unique" on every cursor scrub -- which
% aborts updateTabValues halfway, so the remaining plot readouts, gauges
% and lamps of the tab stop updating. Sort by time (stable) and drop
% repeated (Time, ID) pairs so every decoded signal is strictly monotonic.
if isempty(trace.Time)
    return
end
[~, ord] = sort(trace.Time);
[~, keep] = unique([trace.Time(ord) trace.ID(ord)], 'rows', 'stable');
ord = ord(sort(keep));
trace.Time = trace.Time(ord);
trace.ID   = trace.ID(ord);
trace.DLC  = trace.DLC(ord);
trace.Data = trace.Data(ord,:);
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

function v = sampleSeriesAtTimes(entry, times)
% Vectorized zero-order-hold sample of a decoded signal at each of `times`
% -- same "last value actually received" semantics as sampleAtTime above,
% just for a whole vector of query times at once (used by the efficiency
% map's Kennfeld computation instead of looping sampleAtTime per point).
if isempty(entry.Time)
    v = nan(size(times));
    return
end
v = interp1(entry.Time, entry.Value, times, 'previous', 'extrap');
before = times <= entry.Time(1);
v(before) = entry.Value(1);
end

function k = kennfeldKeys()
% The decoded signals the efficiency map is computed from. Curr (0x386,
% 10 Hz) is preferred; CurrSlow (0x186, 1 Hz in both BMS variants) is only
% the fallback -- zero-order-held against the 10 Hz torque it gave ~6x the
% per-cell scatter. Aux12V is optional (aux-load model).
k.Speed    = 'Skai_Motor_data.Motor_speed';
k.Torque   = 'Skai_Motor_Torque_Voltage.skai_torque';
k.Volt     = 'BMS_Battery_voltage_current_SoC.Battery_voltage';
k.Curr     = 'BMS_Dynamic_Current_Limits.Battery_current';
k.CurrSlow = 'BMS_Battery_voltage_current_SoC.Battery_current';
k.Aux12V   = 'Charger_status_2nd_PDO.DCDC_12V_Current';
end

function s = emptyKennfeldSets()
s = struct('Label',{},'N',{},'T',{},'Eta',{},'Pmech',{},'Pbatt',{},'Count',{},'Visible',{}, ...
    'K',{},'KInfo',{},'AuxInfo',{},'CurrInfo',{});
end

function applyKennfeldColors(ax, cb)
% Shared color scale for the efficiency map (2D scatter + 3D surface):
% red = bad, yellow = mid, green = good. The scale is spread over
% 70-100 % only, since everything below 70 % is uninteresting anyway --
% those values saturate at full red, so the whole color range resolves
% the differences that matter.
lo = 70; hi = 100;
n = 256;
t = linspace(0, 1, n)';
red    = [0.80 0.10 0.10];
yellow = [0.98 0.85 0.15];
green  = [0.10 0.60 0.20];
half = t < 0.5;
s1 = t(half) / 0.5;
s2 = (t(~half) - 0.5) / 0.5;
cmap = zeros(n, 3);
cmap(half,:)  = red    + s1 .* (yellow - red);
cmap(~half,:) = yellow + s2 .* (green - yellow);
colormap(ax, cmap);
clim(ax, [lo hi]);
if nargin >= 2 && ~isempty(cb)
    cb.Ticks = lo:5:hi;
    cb.TickLabels = [{sprintf('≤%d', lo)}, arrayfun(@num2str, lo+5:5:hi, 'UniformOutput', false)];
end
end

function missing = kennfeldMissingKeys(decoded)
k = kennfeldKeys();
needed = {k.Speed, k.Torque, k.Volt};
missing = needed(~isKey(decoded, needed));
if ~isKey(decoded, k.Curr) && ~isKey(decoded, k.CurrSlow)
    missing{end+1} = [k.Curr ' / ' k.CurrSlow];
end
end

function s = kennfeldFilterDesc(settings)
if settings.SteadyState
    s = sprintf(['Steady-State-Filter: AN\n' ...
        '   Fenster: %.3g s\n   Max. |ΔDrehzahl|: %.4g rpm\n   Max. |ΔMoment|: %.4g Nm'], ...
        settings.Window, settings.MaxDSpeed, settings.MaxDTorque);
else
    s = 'Steady-State-Filter: AUS (alle Rohpunkte)';
end
end

function newSet = computeKennfeldSet(decoded, label, settings)
% One efficiency-map dataset from one decoded trace -- see the comment
% block above buildEfficiencyMapTabContent for the eta definition and the
% sign convention. Caller must have checked kennfeldMissingKeys first.
if ~isfield(settings, 'Aux');     settings.Aux = false;   end
if ~isfield(settings, 'KMode');   settings.KMode = 'off'; end
if ~isfield(settings, 'KManual'); settings.KManual = 1;   end

k = kennfeldKeys();
torqueEntry = decoded(k.Torque);
tGrid  = torqueEntry.Time;
torque = torqueEntry.Value;
speed  = sampleSeriesAtTimes(decoded(k.Speed), tGrid);
volt   = interpSeriesAtTimes(decoded(k.Volt), tGrid, Inf);
% |I| > 1000 A: the new BMS sends one -1300 A frame at boot in 0x386.
if isKey(decoded, k.Curr)
    curr = interpSeriesAtTimes(decoded(k.Curr), tGrid, 1000);
    currInfo = 'Strom: 0x386 (10 Hz), interpoliert';
else
    curr = interpSeriesAtTimes(decoded(k.CurrSlow), tGrid, 1000);
    currInfo = 'Strom: 0x186 (1 Hz, 0x386 fehlt) -- deutlich mehr Streuung';
end

omega    = speed * (2*pi/60);
pMechRaw = torque .* omega;
pBatt    = -(volt .* curr);

% Auxiliary base load (12 V system via DCDC) is part of P_batt but not of
% the drivetrain -- it drags eta down at low power.
if settings.Aux
    [pAux, auxInfo] = estimateAuxPower(decoded, tGrid, speed, torque, pBatt);
else
    pAux = zeros(size(pBatt));
    auxInfo = 'Grundlast: nicht abgezogen';
end
pBattNet = pBatt - pAux;

% Torque gain k -- estimated from the gross P_batt: a constant aux load
% only shifts each cell's intercept, not the slope k.
switch settings.KMode
    case 'auto'
        [kEst, nCells, kSd] = estimateTorqueGain(speed, torque, pMechRaw, pBatt);
        if isfinite(kEst)
            kVal = kEst;
            kInfo = sprintf('k = %.3f (Spiegelpunkt, %d Zellen, Streuung ±%.3f)', kEst, nCells, kSd);
        else
            kVal = settings.KManual;
            kInfo = sprintf(['k = %.3f (Fallback-Wert -- Spiegelpunkt nicht schätzbar, ' ...
                '%d Zellen mit Motor- UND Generatorbetrieb, min. 2 nötig)'], kVal, nCells);
        end
    case 'manual'
        kVal = settings.KManual;
        kInfo = sprintf('k = %.3f (manuell)', kVal);
    otherwise
        kVal = 1;
        kInfo = 'k = 1 (keine Momentkorrektur)';
end
pMech = kVal * pMechRaw;

% Guard against dividing by near-zero battery power (idle/coast) -- not a
% real efficiency reading, just numeric noise that would blow up the
% ratio, so these points are dropped rather than plotted or averaged away.
minBattPowerW = 100;
valid = isfinite(pMech) & isfinite(pBattNet) & abs(pBattNet) >= minBattPowerW;
if settings.SteadyState
    valid = valid & computeSteadyStateMask(tGrid, speed, torque, ...
        settings.Window, settings.MaxDSpeed, settings.MaxDTorque);
end

newSet.Label    = label;
newSet.N        = speed(valid);
newSet.T        = torque(valid);
newSet.Eta      = pMech(valid) ./ pBattNet(valid);
newSet.Pmech    = pMech(valid);
newSet.Pbatt    = pBattNet(valid);
newSet.Count    = sum(valid);
newSet.Visible  = true;
newSet.K        = kVal;
newSet.KInfo    = kInfo;
newSet.AuxInfo  = auxInfo;
newSet.CurrInfo = currInfo;
end

function v = interpSeriesAtTimes(entry, times, maxAbs)
% Linear interpolation of a decoded signal at `times`, after dropping
% non-finite and |value| > maxAbs samples. NaN outside the signal's own
% time range (no extrapolation). Used for the slow BMS signals, where the
% zero-order hold of sampleSeriesAtTimes would add up to one message
% period of lag.
ok = isfinite(entry.Value) & abs(entry.Value) <= maxAbs;
t = entry.Time(ok);
x = entry.Value(ok);
[t, iu] = unique(t);
x = x(iu);
if numel(t) < 2
    v = nan(size(times));
    return
end
v = interp1(t, x, times, 'linear', NaN);
end

function [k, nCells, kSd] = estimateTorqueGain(speed, torque, pMechRaw, pBatt)
% "Mirror-point" estimate of the torque-signal gain k = P_mech,true /
% P_mech,reported, without any reference measurement: at the same speed
% and |torque| the drivetrain losses L are about the same whether motoring
% or braking, so within one (speed, |torque|) cell
%     P_batt = k * P_mech,reported + L
% holds for BOTH quadrants and a straight-line fit over the cell's
% motoring (P_mech > 0) and regen (P_mech < 0) points gives k as slope
% and L as intercept. Any calibration error of the torque signal (the
% motor controller's estimate, not a measurement) shows up as k != 1.
% Needs cells with both motoring and regen data -- traces without enough
% regen return NaN.
% Cell edges are relative to the trace's own 99th-percentile speed and
% |torque|, so other vehicles/controller parameters get a sensible grid
% too (for the SAM at 6000 rpm / 50 Nm: 1000-rpm steps, 5/8/12/16/22/30/50 Nm).
minPerSide = 30;
k = NaN; kSd = NaN; nCells = 0;
ok = isfinite(speed) & isfinite(torque) & isfinite(pMechRaw) & isfinite(pBatt);
if nnz(ok) < 2*minPerSide
    return
end
nMax = prctile(speed(ok), 99);
tMax = prctile(abs(torque(ok)), 99);
if ~(nMax > 0) || ~(tMax > 0)
    return
end
nEdges = [(1:6) * nMax/6, Inf];
tEdges = [0.10 0.16 0.24 0.32 0.44 0.60 1.00] * tMax;
tEdges(end) = Inf;
absT = abs(torque);
ks = []; ws = [];
for i = 1:numel(nEdges)-1
    inN = ok & speed >= nEdges(i) & speed < nEdges(i+1);
    for j = 1:numel(tEdges)-1
        sel = inN & absT >= tEdges(j) & absT < tEdges(j+1);
        nMot = nnz(sel & torque > 0);
        nReg = nnz(sel & torque < 0);
        if nMot < minPerSide || nReg < minPerSide
            continue
        end
        coef = [pMechRaw(sel), ones(nnz(sel),1)] \ pBatt(sel);
        ks(end+1) = coef(1); %#ok<AGROW>
        ws(end+1) = min(nMot, nReg); %#ok<AGROW>
    end
end
nCells = numel(ks);
if nCells < 2
    return
end
kW = sum(ks .* ws) / sum(ws);
if kW < 0.3 || kW > 2
    return   % implausible -- more likely a signal/sign problem than a gain error
end
k = kW;
kSd = sqrt(sum(ws .* (ks - kW).^2) / sum(ws));
end

function [pAux, info] = estimateAuxPower(decoded, tGrid, speed, torque, pBatt)
% Auxiliary base load drawn from the HV battery (12 V system via DCDC,
% pumps, ...), estimated from the trace's own standstill samples (motor
% at rest, no torque): P_batt there is pure auxiliary load. If the DCDC's
% 12 V output current explains that standstill power well (r >= 0.5, as
% on the original-BMS car: ~15 W/A = 13.8 V / 0.9), it's modelled as
% a + b*I_12V at every sample, else as the constant standstill median (the
% new-BMS car: no correlation, flat ~120-210 W per trip).
st = abs(speed) < 5 & abs(torque) < 0.3 & isfinite(pBatt);
if nnz(st) < 20
    pAux = zeros(size(pBatt));
    info = 'Grundlast: kein Stillstand in der Messung -- nicht abgezogen';
    return
end
base = median(pBatt(st));
pAux = repmat(base, size(pBatt));
info = sprintf('Grundlast: %.0f W konstant (Median Stillstand)', base);

k = kennfeldKeys();
if ~isKey(decoded, k.Aux12V)
    return
end
i12 = sampleSeriesAtTimes(decoded(k.Aux12V), tGrid);
use = st & isfinite(i12);
if nnz(use) < 20 || diff(prctile(i12(use), [5 95])) < 1
    return
end
r = corrcoef(i12(use), pBatt(use));
r = r(1,2);
p = polyfit(i12(use), pBatt(use), 1);
if r >= 0.5 && p(1) > 0
    model = polyval(p, i12);
    model(~isfinite(model)) = base;
    pAux = model;
    info = sprintf('Grundlast: %.0f W + %.1f W/A · I_DCDC12V (r = %.2f)', p(2), p(1), r);
end
end

function mask = computeSteadyStateMask(tGrid, seriesA, seriesB, windowSec, maxDeltaA, maxDeltaB)
% "Steady state" at sample i = both seriesA and seriesB (Speed, Torque)
% stay within maxDeltaA/maxDeltaB of their own min/max over a
% +-windowSec/2 time window centered on tGrid(i). tGrid must be sorted
% ascending, which every decoded signal's own timestamps already are in
% this app. Two-pointer sliding window: both window edges only move
% forward as the center advances, so this is O(n) despite tGrid being
% non-uniformly spaced (real CAN messages, not a fixed sample rate).
n = numel(tGrid);
mask = false(n,1);
if n == 0
    return
end
halfWin = windowSec / 2;
lo = 1;
hi = 1;
for i = 1:n
    tLo = tGrid(i) - halfWin;
    tHi = tGrid(i) + halfWin;
    while lo < i && tGrid(lo) < tLo
        lo = lo + 1;
    end
    while hi < n && tGrid(hi+1) <= tHi
        hi = hi + 1;
    end
    idx = lo:hi;
    mask(i) = (max(seriesA(idx)) - min(seriesA(idx))) <= maxDeltaA && ...
              (max(seriesB(idx)) - min(seriesB(idx))) <= maxDeltaB;
end
end

function [Xc, Yc, Zc] = binKennfeldPoints(N, T, Eta, binWidthN, binWidthT, minPointsPerCell)
% Grids scattered (N,T,Eta) points onto a regular Drehzahl x Moment mesh,
% averaging Eta within each cell -- the "nearby points merged as mean"
% step feeding the 3D Kennfeldflaeche surface (showKennfeld3DPopup). A
% cell with fewer than minPointsPerCell raw points is left NaN (a gap in
% the surface, since surf() simply skips NaN vertices) rather than shown
% from a single/unreliable sample.
Xc = []; Yc = []; Zc = [];
if isempty(N)
    return
end
binWidthN = max(binWidthN, eps);
binWidthT = max(binWidthT, eps);

edgesN = min(N):binWidthN:(max(N)+binWidthN);
if numel(edgesN) < 2
    edgesN = [min(N), min(N)+binWidthN];
end
edgesT = min(T):binWidthT:(max(T)+binWidthT);
if numel(edgesT) < 2
    edgesT = [min(T), min(T)+binWidthT];
end

binIdxN = discretize(N, edgesN);
binIdxT = discretize(T, edgesT);
valid = ~isnan(binIdxN) & ~isnan(binIdxT);

nBinsN = numel(edgesN) - 1;
nBinsT = numel(edgesT) - 1;
linIdx = sub2ind([nBinsT, nBinsN], binIdxT(valid), binIdxN(valid));

sumEta = accumarray(linIdx, Eta(valid), [nBinsT*nBinsN, 1], @sum, 0);
cnt    = accumarray(linIdx, 1,          [nBinsT*nBinsN, 1], @sum, 0);
sumEta = reshape(sumEta, nBinsT, nBinsN);
cnt    = reshape(cnt,    nBinsT, nBinsN);

meanEta = sumEta ./ cnt;              % 0/0 -> NaN automatically (empty cell)
meanEta(cnt < minPointsPerCell) = NaN;

centersN = (edgesN(1:end-1) + edgesN(2:end)) / 2;
centersT = (edgesT(1:end-1) + edgesT(2:end)) / 2;
[Xc, Yc] = meshgrid(centersN, centersT);
Zc = meanEta * 100;
end

function Zk = kennfeldCornerHeights(Zc)
% Corner heights for the 3D Kennfeld surface: Zc is the nT x nN cell-mean
% grid (NaN = empty cell), Zk the (nT+1) x (nN+1) grid of cell corners.
% Each corner = mean of the (up to 4, diagonal ones included) filled cells
% touching it; corners touching no filled cell stay NaN (never referenced
% by a face). An isolated cell's corners therefore all equal its own mean.
filled = ~isnan(Zc);
z = Zc;
z(~filled) = 0;
sumK = zeros(size(Zc) + 1);
cntK = zeros(size(Zc) + 1);
for di = 0:1
    for dj = 0:1
        rows = (1:size(Zc,1)) + di;
        cols = (1:size(Zc,2)) + dj;
        sumK(rows, cols) = sumK(rows, cols) + z;
        cntK(rows, cols) = cntK(rows, cols) + filled;
    end
end
Zk = sumK ./ cntK;   % 0/0 -> NaN for untouched corners
end

function res = computeCellResistance(decoded, opts)
% Effective internal resistance of each of the 36 cells from the voltage
% drop under load -- see buildCellResistanceTabContent for the method
% overview and PROJECT_NOTES.md for the data findings behind it.
%   decoded : containers.Map from decodeMessages
%   opts    : .Lag (s, NaN = auto), .MinDI (A), .MaxDT (s), .Threshold (%),
%             .TRange ([lo hi] s)
% R is in mOhm (mV per A). Sign convention: Battery_current is negative
% while discharging, so a discharge step gives dI < 0 and dV < 0 -> R > 0.
nCells = 36;
vMinPlaus = 1500;  vMaxPlaus = 5000;   % mV -- rejects the 0 mV startup frames
iMaxPlaus = 1000;                      % A  -- rejects the -1300 A startup frame
spikeMV   = 800;                       % mV -- isolated single-reading glitch, see below
minPairs  = 15;

% Per-cell readings and consecutive-pair bookkeeping, concatenated into
% one long vector so the lag scan needs only one interp1 per lag.
tAll = []; vAll = []; cellAll = [];
Vmean = nan(nCells,1); Vmin = nan(nCells,1);
for k = 1:nCells
    key = sprintf('BMS_Cell_voltage_and_temperature.Cell_voltage_%02d', k);
    if ~isKey(decoded, key); continue; end
    e = decoded(key);
    m = e.Value >= vMinPlaus & e.Value <= vMaxPlaus & e.Time >= opts.TRange(1) & e.Time <= opts.TRange(2);
    t = e.Time(m); v = e.Value(m);
    % Isolated spikes: during the first 0x406 cycle after BMS boot some
    % cells report e.g. 748 / 1993 mV exactly once (seen in several
    % traces). Drop a reading that sits > spikeMV away from the median of
    % its neighbouring readings of the same cell -- a genuine load step
    % between two readings stays far below that (new-BMS car, PEAK logs:
    % ~0.7 mOhm * 200 A = 140 mV; original-BMS car, SAMPlay_Logs/Durs:
    % ~2.6 mOhm * 150 A = 390 mV),
    % while the boot glitches sit >= 1700 mV off.
    if numel(v) >= 3
        prevV = [v(2); v(1:end-1)];
        nextV = [v(2:end); v(end-1)];
        ref = (prevV + nextV) / 2;
        keep = abs(v - ref) <= spikeMV | abs(prevV - nextV) > spikeMV;
        t = t(keep); v = v(keep);
    end
    if isempty(t); continue; end
    Vmean(k) = mean(v);  Vmin(k) = min(v);
    tAll = [tAll; t(:)]; vAll = [vAll; v(:)]; cellAll = [cellAll; repmat(k,numel(t),1)]; %#ok<AGROW>
end
if isempty(tAll)
    error('Keine Zellspannungen (0x406) im gewählten Bereich.');
end
a = (1:numel(tAll)-1)';  b = a + 1;
pairOk = cellAll(a) == cellAll(b) & (tAll(b) - tAll(a)) <= opts.MaxDT;
a = a(pairOk);  b = b(pairOk);
dV = vAll(b) - vAll(a);
pairCell = cellAll(a);

% Current source + lag. Candidates: 0x386 (10 Hz) and 0x186 (1 Hz).
% Which one fits the cell voltages better depends on the BMS: with the
% newly developed BMS (PEAK logs, 'Normale Fahrten') 0x386 at ~1 s lag is
% best; with the original BMS (SAMPlay_Logs/Durs) 0x186 fits about as
% well at ~0.1-0.3 s lag. So
% each available source gets its own lag scan (pooled correlation of dV
% vs dI over all cells), and 'auto' takes 0x186 only if it beats 0x386 by
% a clear margin -- a 1 Hz zero-order hold otherwise loses load steps.
currKeys  = {'BMS_Dynamic_Current_Limits.Battery_current', 'BMS_Battery_voltage_current_SoC.Battery_current'};
currNames = {'0x386 (10 Hz)', '0x186 (1 Hz)'};
if ~isfield(opts, 'CurrentSource'); opts.CurrentSource = 'auto'; end
switch opts.CurrentSource
    case '0x386', cand = 1;
    case '0x186', cand = 2;
    otherwise,    cand = [1 2];
end
cand = cand(isKey(decoded, currKeys(cand)));
if isempty(cand)
    error('Kein Batteriestrom (%s) in dieser Messung.', strjoin(currNames, ' / '));
end
lags = (-0.5:0.05:3)';
src = struct('Idx',{}, 'Name',{}, 't',{}, 'v',{}, 'Corr',{}, 'BestLag',{}, 'BestCorr',{});
for ci = cand
    ce = decoded(currKeys{ci});
    ok = isfinite(ce.Value) & abs(ce.Value) <= iMaxPlaus;
    tI = ce.Time(ok);  vI = ce.Value(ok);
    [tI, iu] = unique(tI);  vI = vI(iu);
    if numel(tI) < 2; continue; end
    corrs = nan(size(lags));
    for li = 1:numel(lags)
        corrs(li) = pairCorr(holdSample(tI, vI, tAll - lags(li)));
    end
    if isnan(opts.Lag)
        [bc, bi] = max(corrs);
        bl = lags(bi);
    else
        bl = opts.Lag;
        bc = pairCorr(holdSample(tI, vI, tAll - bl));
    end
    src(end+1) = struct('Idx',ci, 'Name',currNames{ci}, 't',tI, 'v',vI, 'Corr',corrs, ...
        'BestLag',bl, 'BestCorr',bc); %#ok<AGROW>
end
if isempty(src)
    error('Zu wenige gültige Stromwerte in dieser Messung.');
end
pick = 1;
if numel(src) == 2 && ~(src(1).BestCorr >= src(2).BestCorr - 0.02)
    pick = 2;   % also when 0x386's correlation is NaN (no current changes)
end
lag = src(pick).BestLag;
lagAuto = isnan(opts.Lag);
Iq = holdSample(src(pick).t, src(pick).v, tAll - lag);
dIall = Iq(b) - Iq(a);
lagCorr = pairCorr(Iq);

% Per-cell robust fit through the origin.
R = nan(nCells,1); CI95 = nan(nCells,1); R2 = nan(nCells,1); NPairs = zeros(nCells,1);
Pairs = cell(nCells,1);
for k = 1:nCells
    m = pairCell == k & isfinite(dIall) & abs(dIall) >= opts.MinDI;
    x = dIall(m);  y = dV(m);
    [R(k), se, R2(k), used] = robustSlopeThroughOrigin(x, y);
    CI95(k) = 1.96 * se;
    NPairs(k) = sum(used);
    if NPairs(k) < minPairs
        R(k) = NaN; CI95(k) = NaN; R2(k) = NaN;
    end
    Pairs{k} = struct('dI', x, 'dV', y, 'Used', used);
end

med = median(R, 'omitnan');
DevPct = 100 * (R - med) / med;
thr = opts.Threshold;
StatusCode = ones(nCells,1);                 % 1 = OK
StatusCode(DevPct > thr/2) = 2;              % erhöht
StatusCode(DevPct > thr)   = 3;              % auffällig
StatusCode(DevPct < -thr)  = 4;              % niedrig
StatusCode(isnan(R))       = 0;              % zu wenig Daten
labels = {'Zu wenig Daten','OK','Erhöht','Auffällig','Niedrig'};
Status = labels(StatusCode + 1)';

% Context for interpreting the result: the BMS's own resistance
% estimate (0x306) and the cell temperatures (0x406), both restricted to
% the analysed time range. The newly developed BMS (PEAK logs) sends
% placeholder values in 0x306 (1.0 everywhere, cell 1 as best AND worst)
% and a near-flat 21-22 C; the original BMS (SAMPlay_Logs/Durs) sends
% real, varying values for both while driving (0.8 / cell 1 placeholders
% again at standstill/charging). Cell numbers
% are summarised by their most frequent value (a median of cell indices
% would be meaningless).
bms = struct('Low',NaN, 'Avg',NaN, 'High',NaN, 'CellLow',NaN, 'CellHigh',NaN, 'CellHighShare',NaN);
pre = 'BMS_State_of_health.';
fld = {'Low','Lowest_internal_resistance'; 'Avg','Average_internal_resistance'; 'High','Highest_internal_resistance'};
for fi = 1:size(fld,1)
    if isKey(decoded, [pre fld{fi,2}])
        e = decoded([pre fld{fi,2}]);
        bms.(fld{fi,1}) = median(e.Value(e.Time >= opts.TRange(1) & e.Time <= opts.TRange(2)), 'omitnan');
    end
end
fld = {'CellLow','Cell_with_lowest_resistance'; 'CellHigh','Cell_with_highest_resistance'};
for fi = 1:size(fld,1)
    if isKey(decoded, [pre fld{fi,2}])
        e = decoded([pre fld{fi,2}]);
        cv = e.Value(e.Time >= opts.TRange(1) & e.Time <= opts.TRange(2) & e.Value >= 1 & e.Value <= nCells);
        if ~isempty(cv)
            bms.(fld{fi,1}) = mode(cv);
            if fi == 2
                bms.CellHighShare = 100 * mean(cv == bms.CellHigh);
            end
        end
    end
end
temp = [NaN NaN NaN];   % p5 / median / p95 over sensors 1-12
tKey = 'BMS_Cell_voltage_and_temperature.Cell_temperature';
sKey = 'BMS_Cell_voltage_and_temperature.Temperature_sensor';
if isKey(decoded, tKey) && isKey(decoded, sKey)
    et = decoded(tKey); es = decoded(sKey);
    m = es.Value >= 1 & es.Value <= 12 & et.Time >= opts.TRange(1) & et.Time <= opts.TRange(2);
    if any(m)
        tv = et.Value(m);
        % 5th/95th percentile rather than min/max: the boot cycle also
        % reports 0 C for some sensors on the newly developed BMS.
        temp = [prctile(tv,5) median(tv) prctile(tv,95)];
    end
end

res = struct('R',R, 'CI95',CI95, 'R2',R2, 'NPairs',NPairs, 'Vmean',Vmean, 'Vmin',Vmin, ...
    'DevPct',DevPct, 'Median',med, 'Threshold',thr, 'StatusCode',StatusCode, 'Status',{Status}, ...
    'Lag',lag, 'LagAuto',lagAuto, 'LagCorr',lagCorr, ...
    'LagScan',struct('Lag',lags, 'Corr',{{src.Corr}}, 'Name',{{src.Name}}, 'Picked',pick), ...
    'CurrentSource',src(pick).Name, 'TRange',opts.TRange, 'Pairs',{Pairs}, 'Bms',bms, 'Temp',temp);

    function c = pairCorr(Isampled)
        % Pooled correlation of dV vs dI over all consecutive same-cell pairs.
        dI = Isampled(b) - Isampled(a);
        f = isfinite(dI);
        c = NaN;
        if sum(f) > 10 && std(dI(f)) > 0
            cc = corrcoef(dI(f), dV(f));
            c = cc(1,2);
        end
    end
end

function v = holdSample(t, val, q)
% Zero-order hold ("last value actually received") like sampleSeriesAtTimes,
% but NaN before the first sample instead of back-filling it -- a cell
% reading from before the first current frame has no valid current.
v = interp1(t, val, q, 'previous', 'extrap');
v(q < t(1)) = NaN;
end

function [slope, se, r2, used] = robustSlopeThroughOrigin(x, y)
% Least-squares y = slope*x with iterative MAD-based outlier rejection
% (residuals beyond 4 robust sigmas, floored at the 1 mV voltage
% quantization). Returns the standard error of the slope and the squared
% correlation of the kept points.
used = true(size(x));
slope = NaN; se = NaN; r2 = NaN;
if numel(x) < 3
    return
end
for it = 1:5
    xs = x(used); ys = y(used);
    slope = sum(xs.*ys) / sum(xs.^2);
    res = y - slope*x;
    sig = max(1.4826 * median(abs(res(used))), 1);
    newUsed = abs(res) <= 4*sig;
    if isequal(newUsed, used) || sum(newUsed) < 3
        break
    end
    used = newUsed;
end
xs = x(used); ys = y(used);
slope = sum(xs.*ys) / sum(xs.^2);
res = ys - slope*xs;
n = numel(xs);
if n > 1
    se = sqrt(sum(res.^2) / (n-1) / sum(xs.^2));
    c = corrcoef(xs, ys);
    r2 = c(1,2)^2;
end
end

function cdata = cellResStatusColors(code)
% Bar colors per status code (see computeCellResistance).
cols = [ 0.70 0.70 0.70     % 0 zu wenig Daten
         0.00 0.447 0.741   % 1 OK
         0.93 0.69 0.13     % 2 erhöht
         0.80 0.15 0.15     % 3 auffällig
         0.30 0.75 0.93 ];  % 4 niedrig
cdata = cols(code(:) + 1, :);
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
