function trace = parseTRC(trcFile)
%PARSETRC Parse a PCAN-View .trc file (v1.x/v2.x) into a trace struct.
%   trace = PARSETRC(trcFile) returns a struct with fields:
%       Time  - Nx1 double, seconds relative to the first frame
%       ID    - Nx1 double, decimal CAN identifier
%       DLC   - Nx1 double, data length code
%       Data  - Nx8 uint8, data bytes (zero-padded past DLC)
%   Only classic "DT" data frames are kept; RTR/error/event rows are skipped.

txt = string(fileread(trcFile));

% Matches rows like:
%  1 617410.260 DT 1801D08F Rx 8 00 8B 00 79 43 00 00 5A
%  3 617455.652 DT 0080 Rx 0
pat = '(?m)^\s*\d+\s+([\d.]+)\s+DT\s+([0-9A-Fa-f]+)\s+(?:Rx|Tx)\s+(\d+)\s*((?:[0-9A-Fa-f]{2}\s*)*)$';
tok = regexp(txt, pat, 'tokens');

n = numel(tok);
if n == 0
    trace = struct('Time',[],'ID',[],'DLC',[],'Data',uint8.empty(0,8));
    return
end

timesMs  = zeros(n,1);
idHex    = strings(n,1);
dlc      = zeros(n,1);
dataStr  = strings(n,1);
for i = 1:n
    t = tok{i};
    timesMs(i) = str2double(t{1});
    idHex(i)   = t{2};
    dlc(i)     = str2double(t{3});
    dataStr(i) = t{4};
end

% Decimal IDs (hex2dec supports mixed-length hex strings in a cell array)
id = hex2dec(cellstr(idHex));

% Decode data bytes (variable length per row, zero-padded to 8)
Data = zeros(n,8,'uint8');
for i = 1:n
    if dlc(i) == 0; continue; end
    b = sscanf(char(dataStr(i)), '%2x');
    m = min(numel(b),8);
    Data(i,1:m) = uint8(b(1:m));
end

t0 = timesMs(1);
trace.Time = (timesMs - t0) / 1000;   % seconds, relative to first frame
trace.ID   = id;
trace.DLC  = dlc;
trace.Data = Data;

end
