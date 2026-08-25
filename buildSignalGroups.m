function groups = buildSignalGroups()
%BUILDSIGNALGROUPS Curated layout of gauges/plots/lamps per subsystem tab.
%   Returns a struct array, one entry per UI tab ("toolbar group"), with:
%       Title       - tab label
%       Gauges      - struct array: Key, Label, Unit, Range [min max]
%       Plots       - struct array: Title, Keys{cell}, Labels{cell}, YLabel
%       Lamps       - struct array: Key, Label (boolean flags)
%       StatusLabels- struct array: Key, Label (enumerated / VAL_ signals)
%       Sections    - struct array: Title, Lamps, StatusLabels, TextBlocks.
%                     When non-empty, the tab is rendered as a grouped
%                     grid of titled panels (one per section) instead of
%                     the normal gauges/plots/strip layout -- used for the
%                     Errors tab so related faults are visually grouped
%                     and rendered at a readable size instead of a thin
%                     bottom strip. TextBlocks (Key/Label/Formatter) are
%                     for signals that need decoding into a multi-line
%                     description (e.g. a bitmask fault register) rather
%                     than a single raw value -- see mksection/mktextblock
%                     below and decodeFecuErrors.m. Leave empty ([]) for
%                     normal tabs.
%       BarCharts   - struct array: Title, Keys{cell}, Labels{cell},
%                     YLabel, Unit, Range [min max]. When non-empty, the
%                     tab is rendered as one bar-chart axes per entry, with
%                     one bar per Key, redrawn (bar heights only, not a
%                     replot) on every cursor scrub -- used for the Cell
%                     Voltages tab (36 bars, one per battery cell) where a
%                     time-series line plot per cell would be unreadable.
%                     See mkbarchart below. Leave empty ([]) for tabs that
%                     don't need this layout.
%   Key = "MessageName.SignalName" matching decodeMessages() output.
%   Signals that aren't present in a given trace are simply skipped by the
%   app at render time, so this list can stay broad across use cases
%   (driving vs. charging sessions activate different message sets).

groups = struct('Title',{},'Gauges',{},'Plots',{},'Lamps',{},'StatusLabels',{},'Sections',{},'BarCharts',{});

%% ---- Battery / BMS ------------------------------------------------
g.Title = 'Battery / BMS';
% NOTE: SoC is read from BMS_dynamic_regen_Current (0x486) rather than
% the BMS_Battery_voltage_current_SoC (0x186) copy of the same field --
% can_io.c explicitly only consumes the 0x486 one ("siehe stateOfCharge
% CAN_0x486"), so that is the value the real vehicle firmware trusts.
g.Gauges = mkgauge({
    'BMS_dynamic_regen_Current.SoC',                   'State of Charge', '%',   [0 100]
    'BMS_Battery_voltage_current_SoC.Battery_voltage', 'Pack Voltage',    'V',   [0 170]
    'BMS_Battery_voltage_current_SoC.Battery_current', 'Pack Current',    'A',   [-250 250]
    'BMS_State_of_health.State_of_health',             'State of Health', '%',   [0 100]
    'BMS_Max_and_min_cell_voltage.Highest_cell_voltage','Max Cell mV',    'mV',  [2500 4300]
    'BMS_Max_and_min_cell_voltage.Lowest_cell_voltage', 'Min Cell mV',    'mV',  [2500 4300]
    });
g.Plots = mkplot({
    'State of Charge',    {'BMS_dynamic_regen_Current.SoC'},                                       {'SoC'},       '%'
    'Pack Voltage',       {'BMS_Battery_voltage_current_SoC.Battery_voltage'},                            {'Voltage'},   'V'
    'Pack Current',       {'BMS_Battery_voltage_current_SoC.Battery_current','BMS_Dynamic_Current_Limits.Battery_current'}, {'BatteryMsg','LimitsMsg'}, 'A'
    'Cell Voltage Spread',{'BMS_Max_and_min_cell_voltage.Highest_cell_voltage','BMS_Max_and_min_cell_voltage.Average_cell_voltage','BMS_Max_and_min_cell_voltage.Lowest_cell_voltage'}, {'Max','Avg','Min'}, 'mV'
    'Charge/Discharge Current Limits', {'BMS_Dynamic_Current_Limits.dynamic_max_charge_current','BMS_Dynamic_Current_Limits.dynamic_max_discharge_Current'}, {'MaxCharge','MaxDischarge'}, 'A'
    'State of Health / Remaining Energy', {'BMS_State_of_health.State_of_health','BMS_State_of_health.Remaining_energy'}, {'SoH %','Energy Wh'}, ''
    });
g.Lamps = mklamp({
    'BMS_Flags.Charge_switch',   'Charge Switch'
    'BMS_Flags.Precharge_switch','Precharge Switch'
    'BMS_Flags.Closed_PC',       'Power Contactor'
    'BMS_Flags.Balancing_active','Balancing'
    });
g.StatusLabels = mkstatus({
    'BMS_Battery_voltage_current_SoC.Battery_status', 'Battery Status'
    });
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Motor / Drive --------------------------------------------------
% ECU_Skai_Control (0x191) is what the ECU commands the motor controller
% to do (requested torque/speed, enable, control mode); Skai_Motor_data,
% Skai_Motor_Torque_Voltage and Skai_Status_Errors (0x190/0x290/0x390)
% are what the motor controller reports back. No firmware source was
% available to verify 0x191's byte layout (can_io.c is the dashboard
% node and never builds this message), so it is taken as given in the DBC.
g.Title = 'Motor / Drive';
g.Gauges = mkgauge({
    'Skai_Motor_data.Motor_speed',              'Motor Speed (actual)', 'rpm', [-3500 7500]
    'ECU_Skai_Control.requested_speed',         'Motor Speed (cmd)',    'rpm', [-3500 7500]
    'Skai_Motor_Torque_Voltage.skai_torque',    'Motor Torque (actual)','Nm',  [-50 50]
    'ECU_Skai_Control.requested_torque',        'Motor Torque (cmd)',   'Nm',  [-50 50]
    'Skai_Motor_Torque_Voltage.skai_DC_Link_Voltage','DC Link Voltage','V', [0 170]
    'Skai_Motor_temperatures.Wicklungstemperatur','Winding Temp','C', [-20 100]
    'Skai_Motor_temperatures.Temperatur_T1',    'Temp T1',     'C',   [-20 100]
    'Skai_Motor_temperatures.Temperatur_T3',    'Temp T3',     'C',   [-20 100]
    });
g.Plots = mkplot({
    'Motor Speed: Actual vs Commanded', {'Skai_Motor_data.Motor_speed','ECU_Skai_Control.requested_speed'}, {'Actual','Commanded'}, 'rpm', [], []
    % Right axis: raw counts, since the 0.005 Nm/count scale (see SAM_CAN.dbc
    % CM_ SG_ 401 requested_torque) is inferred from the +-10000 clip point
    % matching the vehicle's real ~50Nm max, not firmware-confirmed -- shown
    % alongside Nm so the underlying raw reading stays visible too.
    'Motor Torque: Actual vs Commanded',{'Skai_Motor_Torque_Voltage.skai_torque','ECU_Skai_Control.requested_torque'}, {'Actual','Commanded'}, 'Nm', [], mkrightaxis(200, 'raw counts', [-50 50])
    'Motor Temperatures', {'Skai_Motor_temperatures.Wicklungstemperatur','Skai_Motor_temperatures.Temperatur_T1','Skai_Motor_temperatures.Temperatur_T3'}, {'Winding','T1','T3'}, 'C', [], []
    'DC Link Voltage',    {'Skai_Motor_Torque_Voltage.skai_DC_Link_Voltage'},  {'DC Link'},'V', [], []
    });
g.Lamps = mklamp({
    'ECU_Skai_Control.Skai_enable',            'Enable Cmd (ECU->Skai)'
    'Skai_Status_Errors.Skai_enabled',         'Skai Enabled (reported)'
    'ECU_Skai_Control.Torque_or_Speed_Control','Speed Ctrl Mode'
    'Skai_Status_Errors.Skai_driveError',      'Skai Drive Error'
    'Skai_Status_Errors.Skai_driveWarning',    'Skai Drive Warning'
    'ECU_Drive_mode_ECU_status.cooling_pump_1', 'Cooling Pump 1'
    'ECU_Drive_mode_ECU_status.cooling_pump_2', 'Cooling Pump 2'
    });
g.StatusLabels = mkstatus({
    'ECU_Drive_mode_ECU_status.Drive_mode', 'Drive Mode'
    });
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Charger / DCDC ---------------------------------------------------
g.Title = 'Charger / DCDC';
g.Gauges = mkgauge({
    'Charger_status_1st_PDO.VoltageHV',   'HV Voltage','V', [0 170], false
    'Charger_status_1st_PDO.VoltageLV',   'LV Voltage','V', [10 16], false
    'Charger_status_1st_PDO.Charger_temperature','Charger Temp','C', [-20 100], false
    'Charger_status_1st_PDO.Charger_heatsink_temperature','Heatsink Temp','C', [-20 100], false
    'Charger_status_2nd_PDO.DCDC_HV_Current','DCDC HV Current (unconfirmed)','A', [0 50], true
    'Charger_status_2nd_PDO.DCDC_12V_Current','DCDC 12V Current','A', [0 25], false
    'Charger_status_2nd_PDO.DCDC_Temperature','DCDC Temp','', [-20 150], false
    });
g.Plots = mkplot({
    'Charger Voltages',   {'Charger_status_1st_PDO.VoltageHV','Charger_status_1st_PDO.VoltageLV'}, {'HV','LV'}, 'V'
    'Charger Temperatures',{'Charger_status_1st_PDO.Charger_temperature','Charger_status_1st_PDO.Charger_heatsink_temperature','Charger_status_2nd_PDO.DCDC_Temperature'}, {'Electronics','Heatsink','DCDC'}, 'C'
    'DCDC Currents',      {'Charger_status_2nd_PDO.DCDC_HV_Current','Charger_status_2nd_PDO.DCDC_12V_Current'}, {'HV','12V'}, 'A'
    'Inside/Outside Temp',{'Charger_informations.Inside_temp','Charger_informations.Outside_temp'}, {'Inside','Outside'}, 'C'
    });
g.Lamps = mklamp({
    'Charger_status_1st_PDO.xCharging',    'Charging'
    'Charger_status_1st_PDO.xBulk_charge', 'Bulk Charge'
    'Charger_status_1st_PDO.xU_Charge',    'U-Charge'
    'Charger_status_1st_PDO.xBattery_full','Battery Full'
    'Charger_status_1st_PDO.xDCDC_on',     'DCDC On'
    'Charger_request.xDCDC_on',            'DCDC Requested'
    });
g.StatusLabels = mkstatus({});
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Vehicle / ECU -------------------------------------------------
g.Title = 'Vehicle / ECU';
g.Gauges = mkgauge({
    'ECU_Pedals_ignition_12V.trip_km',           'Trip','km', [0 100000], false
    'ECU_Pedals_ignition_12V.acceleration_Pedal','Accel Pedal (raw)','counts', [0 65535], true
    'ECU_Pedals_ignition_12V.break_pedal',       'Brake Pedal (raw)','counts', [0 65535], true
    });
g.Plots = mkplot({
    % Right axis: raw counts are a 16-bit unsigned field (0-65535 span,
    % see PROJECT_NOTES "acceleration_Pedal/break_pedal" -- unconfirmed
    % scale, but pedal travel ramps smoothly across the full raw range in
    % every trace) -- 0-100% maps linearly onto the same 0-65535 span.
    'Pedals',       {'ECU_Pedals_ignition_12V.acceleration_Pedal','ECU_Pedals_ignition_12V.break_pedal'}, {'Accel','Brake'}, 'counts (raw)', {}, mkrightaxis(100/65535, '%', [0 65535])
    'Drive Mode',   {'ECU_Drive_mode_ECU_status.Drive_mode'}, {'Mode'}, '', {0,'ECO';2,'Sport';3,'Snow'}, []
    'Trip Distance',{'ECU_Pedals_ignition_12V.trip_km'}, {'Trip'}, 'km', {}, []
    });
g.Lamps = mklamp({
    'ECU_Pedals_ignition_12V.Ignition_Key_1_K15', 'Ignition K15'
    'ECU_Pedals_ignition_12V.Ignition_Key_2',     'Ignition Key 2'
    'ECU_Pedals_ignition_12V.Ignition_Key_Kick_K50','Kick K50'
    'ECU_Pedals_ignition_12V.driving',            'Driving'
    'ECU_Pedals_ignition_12V.Gear_D',             'Gear D'
    'ECU_Pedals_ignition_12V.Gear_R',              'Gear R'
    'ECU_Drive_mode_ECU_status.break_error',      'Brake Error'
    'ECU_Drive_mode_ECU_status.accel_error',      'Accel Error'
    'ECU_Drive_mode_ECU_status.charger_error',    'Charger Error'
    });
g.StatusLabels = mkstatus({});
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Dashboard / Doors -----------------------------------------------
g.Title = 'Dashboard / Doors';
g.Gauges = mkgauge({
    'Dashboard_Controller_DRV_mode.fan_Speed', 'Fan Speed','', [0 255]
    'Dashboard_Controller.buzzer_frequenzy',   'Buzzer Freq','', [0 255]
    'Dashboard_Controller.gauges_illumination','Illumination','', [0 255]
    });
g.Plots = mkplot({
    'Fan Speed',       {'Dashboard_Controller_DRV_mode.fan_Speed'}, {'Fan'}, ''
    'Dash Illumination',{'Dashboard_Controller.gauges_illumination'}, {'Illum'}, ''
    });
g.Lamps = mklamp({
    'Dashboard_Controller.Gear_D', 'Gear D'
    'Dashboard_Controller.Gear_N', 'Gear N'
    'Dashboard_Controller.Gear_R', 'Gear R'
    'PDC_02.PDC_Status',           'Door Ctrl Status'
    });
g.StatusLabels = mkstatus({
    'Dashboard_Controller_DRV_mode.selected_driving_mode', 'Selected Mode'
    });
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Errors ------------------------------------------------------
% Cross-vehicle fault/warning overview, grouped into one panel per
% subsystem so related faults read together instead of as one long thin
% strip. Lamps go red the instant a fault code is non-zero at the
% scrubbed time; the status rows alongside show the actual fault code so
% you can tell WHICH fault it is, not just that one exists.
% Skai_Status_Errors signals are ground-truthed against can_io.c (case
% 0x190); the rest come from the DBC as given.
g.Title = 'Errors';
g.Gauges = mkgauge({});
% Plotted alongside the fault panels below so that when one fault trips
% others in a chain reaction, the FIRST rising edge (in time) shows which
% one actually started it -- the text block only shows the code at the
% currently-scrubbed instant, not its history.
g.Plots = mkplot({
    'FECU Fault Code (raw)', {'ECU_Drive_mode_ECU_status.FECU_error'}, {'FECU code'}, 'raw bitmask'
    });
g.Lamps = mklamp({});
g.StatusLabels = mkstatus({});
g.Sections = [ ...
    mksection('Motor Controller (Skai)', { ...
        'Skai_Status_Errors.Skai_powerModuleError', 'Power Module Error'
        'Skai_Status_Errors.Skai_hardwareError',    'Hardware Error'
        'Skai_Status_Errors.Skai_driveError',       'Drive Error'
        'Skai_Status_Errors.Skai_driveWarning',     'Drive Warning'
        }, { ...
        'Skai_Status_Errors.Skai_powerModuleError', 'Power Module Code'
        'Skai_Status_Errors.Skai_hardwareError',    'Hardware Code'
        'Skai_Status_Errors.Skai_driveError',       'Drive Error Code'
        'Skai_Status_Errors.Skai_driveWarning',     'Drive Warning Code'
        }) ...
    mksection('Vehicle ECU', { ...
        'ECU_Drive_mode_ECU_status.break_error',   'Brake Error'
        'ECU_Drive_mode_ECU_status.accel_error',   'Accel Error'
        'ECU_Drive_mode_ECU_status.charger_error', 'Charger Error (ECU)'
        }, {}, { ...
        'ECU_Drive_mode_ECU_status.FECU_error', 'FECU Fault Register (decoded)', @decodeFecuErrors
        }) ...
    mksection('Charger / DCDC', { ...
        'Charger_status_2nd_PDO.DCDC_Warnings', 'DCDC Warning'
        }, { ...
        'Charger_status_1st_PDO.Charger_error', 'Charger Error Code'
        'Charger_status_2nd_PDO.DCDC_Warnings', 'DCDC Warning Code'
        }) ...
    mksection('BMS', { ...
        'BMS_Flags.error_precence',                  'Error Present'
        'BMS_Flags.Leakage',                         'Leakage'
        'BMS_Flags.Lem_overcurrent',                 'LEM Overcurrent'
        'BMS_Flags.second_protection_overcharge',    'Overcharge Protect'
        'BMS_Flags.second_protection_overdischarge', 'Overdischarge Protect'
        'BMS_Flags.Supervision_positive_12V',        '+12V Supervision'
        'BMS_Flags.Supervision_negative_12V',        '-12V Supervision'
        }, { ...
        'BMS_Emergency.error_register', 'EMCY Error Register'
        'BMS_Emergency.EMCY_ID',        'EMCY ID'
        }) ...
    ];
g.BarCharts = mkbarchart({});
groups(end+1) = g; clear g

%% ---- Cell Voltages -------------------------------------------------
% One bar chart, 36 bars (Cell 1-36), redrawn at every scrub from the
% per-cell entries decodeMessages.m splits out of
% BMS_Cell_voltage_and_temperature (CAN 0x406, multiplexed one-cell-per-
% frame). Firmware (can_io.c, case 0x406) numbers cells 1-36 with a
% little-endian uint16 mV value, matching this DBC's layout exactly, so no
% correction was needed here (unlike several other messages -- see
% PROJECT_NOTES.md). Range mirrors the Battery/BMS tab's Max/Min Cell mV
% gauges.
g.Title = 'Cell Voltages';
g.Gauges = mkgauge({});
g.Plots = mkplot({});
g.Lamps = mklamp({});
g.StatusLabels = mkstatus({});
g.Sections = struct('Title',{},'Lamps',{},'StatusLabels',{});
g.BarCharts = mkbarchart({
    'Cell Voltages (1-36)', 'BMS_Cell_voltage_and_temperature', 'Cell_voltage', 36, 'Voltage', 'mV', [2500 4300]
    });
groups(end+1) = g; clear g

end

% ---- small local builders to keep the table literals above readable ----
function s = mkgauge(rows)
% Optional 5th column: Uncertain (true = scale not confirmed against
% firmware, rendered as a raw/uncalibrated reading in the UI).
s = struct('Key',{},'Label',{},'Unit',{},'Range',{},'Uncertain',{});
for i=1:size(rows,1)
    s(i).Key = rows{i,1}; s(i).Label = rows{i,2}; s(i).Unit = rows{i,3}; s(i).Range = rows{i,4};
    if size(rows,2) >= 5
        s(i).Uncertain = rows{i,5};
    else
        s(i).Uncertain = false;
    end
end
end

function s = mkplot(rows)
% Optional 5th column: YValMap, an Nx2 cell {rawValue,label} for
% categorical/enumerated signals (e.g. Drive_mode) -- rendered as Y-axis
% tick labels instead of raw numbers so the time course reads directly.
% Optional 6th column: RightAxis (see mkrightaxis below) -- adds a second
% Y-axis on the right of the plot, linearly tied to the left axis, e.g.
% raw counts (left) vs. percent (right).
s = struct('Title',{},'Keys',{},'Labels',{},'YLabel',{},'YValMap',{},'RightAxis',{});
for i=1:size(rows,1)
    s(i).Title = rows{i,1}; s(i).Keys = rows{i,2}; s(i).Labels = rows{i,3}; s(i).YLabel = rows{i,4};
    if size(rows,2) >= 5
        s(i).YValMap = rows{i,5};
    else
        s(i).YValMap = [];
    end
    if size(rows,2) >= 6
        s(i).RightAxis = rows{i,6};
    else
        s(i).RightAxis = [];
    end
end
end

function r = mkrightaxis(factor, unit, leftLimits)
% RightAxis descriptor for mkplot's 6th column: a second Y-axis on the
% right, always kept linearly in sync with the left axis via
% rightValue = leftValue * Factor. LeftLimits fixes the left axis's range
% (needed so the two sides don't drift out of sync under autoscaling).
r.Factor = factor;
r.Unit = unit;
r.LeftLimits = leftLimits;
end

function s = mklamp(rows)
s = struct('Key',{},'Label',{});
for i=1:size(rows,1)
    s(i).Key = rows{i,1}; s(i).Label = rows{i,2};
end
end

function s = mkstatus(rows)
s = struct('Key',{},'Label',{});
for i=1:size(rows,1)
    s(i).Key = rows{i,1}; s(i).Label = rows{i,2};
end
end

function s = mkbarchart(rows)
% One row per bar-chart panel: {Title, KeyPrefix, SignalName, NumBars,
% YLabel, Unit, Range}. Keys are auto-generated as
% "KeyPrefix.SignalName_NN" (NN = 01..NumBars, zero-padded) to match the
% per-cell entries decodeMessages.m splits out for multiplexed per-cell
% messages (see BMS_Cell_voltage_and_temperature / CAN 0x406). Labels are
% just the bar index (1..NumBars) as the X-axis category.
s = struct('Title',{},'Keys',{},'Labels',{},'YLabel',{},'Unit',{},'Range',{});
for i = 1:size(rows,1)
    n = rows{i,4};
    keys = cell(1,n);
    labels = cell(1,n);
    for k = 1:n
        keys{k} = sprintf('%s.%s_%02d', rows{i,2}, rows{i,3}, k);
        labels{k} = sprintf('%d', k);
    end
    s(i).Title = rows{i,1};
    s(i).Keys = keys;
    s(i).Labels = labels;
    s(i).YLabel = rows{i,5};
    s(i).Unit = rows{i,6};
    s(i).Range = rows{i,7};
end
end

function s = mksection(title, lampRows, statusRows, textRows)
% textRows (optional): Nx3 cell {Key, Label, FormatterFcn}. Used for
% signals that need decoding into a multi-line human-readable text block
% (e.g. a bitmask fault register) rather than a single raw/VAL_ code --
% see the FECU fault register in the Errors tab and decodeFecuErrors.m.
if nargin < 4
    textRows = {};
end
s.Title = title;
s.Lamps = mklamp(lampRows);
s.StatusLabels = mkstatus(statusRows);
s.TextBlocks = mktextblock(textRows);
end

function s = mktextblock(rows)
s = struct('Key',{},'Label',{},'Formatter',{});
for i=1:size(rows,1)
    s(i).Key = rows{i,1}; s(i).Label = rows{i,2}; s(i).Formatter = rows{i,3};
end
end
