function [lines, severity] = decodeFecuErrors(v)
%DECODEFECUERRORS Decode the SAM FECU fault bitmask into readable text.
%   [lines, severity] = decodeFecuErrors(v)
%   v is the raw value of ECU_Drive_mode_ECU_status.FECU_error (CAN ID
%   0x292, bytes B5-B7, 24-bit bitmask; multiple simultaneous errors are
%   added, e.g. 0x0F000 = 0x01000|0x02000|0x04000|0x08000).
%   lines    - cell array of strings, one per line (feed straight into a
%              uilabel's Text property for automatic multi-line display)
%   severity - 'critical' | 'warning' | 'ok' | 'na'
%
%   Source: SAM2_FECU_Errorhandling.pdf (S.A.M. Group AG), FECU 1.87+,
%   20.08.2012, B. Galliker.

if nargin < 1 || isempty(v) || isnan(v)
    lines = {'N/A'};
    severity = 'na';
    return
end

v = uint32(round(v));
table = fecuErrorTable();

if v == 0
    lines = {sprintf('0x%05X -- no errors active', v)};
    severity = 'ok';
    return
end

lines = {sprintf('Code 0x%05X:', v)};
anyCritical = false;
for i = 1:size(table,1)
    mask = uint32(table{i,1});
    if bitand(v, mask) ~= 0
        isCritical = table{i,3};
        if isCritical
            tag = 'CRITICAL';
            anyCritical = true;
        else
            tag = 'warning';
        end
        lines{end+1} = sprintf('%s: %s', tag, table{i,2}); %#ok<AGROW>
    end
end

if anyCritical
    severity = 'critical';
else
    severity = 'warning';
end
end

% ---------------------------------------------------------------------
function t = fecuErrorTable()
% {bitmask, description, isCritical}
t = {
    hex2dec('00001'),  'SKAI control Error',                                          true
    hex2dec('00002'),  'Accel/brake threshold error',                                 true
    hex2dec('00004'),  'Accel/brake differential error',                              false
    hex2dec('00008'),  'SKAI error (after clearing errors, after 2s)',                true
    hex2dec('00010'),  'SKAI Undervoltage Error',                                     true
    hex2dec('00020'),  'SKAI Encoder Error',                                          true
    hex2dec('00040'),  'BMS/SKAI main battery voltage differ (PC closed)',            true
    hex2dec('00080'),  'BMS did not close PC after 5s',                               true
    hex2dec('00100'),  'No SKAI on CAN (after 5s)',                                   true
    hex2dec('00200'),  'No BMS on CAN (after 2s)',                                    true
    hex2dec('00400'),  'No Charger on CAN (after 2s)',                                false
    hex2dec('00800'),  'No DC on CAN (after 1s)',                                     true
    hex2dec('01000'),  'SKAI other error',                                            true
    hex2dec('02000'),  'Charging stopped: too many BMS error clear attempts (4)',     true
    hex2dec('04000'),  'Charger did not turn on DC/DC while PC closed (after 5s)',    false
    hex2dec('08000'),  'Charger error (after clearing, after 2s, after 5 retries)',   true
    hex2dec('10000'),  'No enable on SKAI, no SKAI errors (after 3s)',                true
    hex2dec('20000'),  'Characteristics loading error',                              true
    hex2dec('40000'),  'Warning: power reduction (BMS/DMDC active)',                  false
    hex2dec('80000'),  'Warning: power reduction (SKAI overtemp.)',                   false
    hex2dec('100000'), 'EMERGENCY BUTTON pressed',                                    true
    hex2dec('200000'), 'No PDC on CAN',                                               false
    };
end
