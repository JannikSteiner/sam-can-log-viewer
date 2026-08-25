function trace = parseSAMPlay(logFile)
%PARSESAMPLAY Parse a SAMPlay logger .TXT export into a trace struct.
%   trace = PARSESAMPLAY(logFile) returns a struct with fields:
%       Time  - Nx1 double, seconds relative to the first frame
%       ID    - Nx1 double, decimal CAN identifier
%       DLC   - Nx1 double, data length code
%       Data  - Nx8 uint8, data bytes (zero-padded past DLC)
%   Rows look like (no header, comma-separated, always 8 data-byte fields
%   regardless of DLC, trailing channel/node name ignored):
%     01402.859488,      02b0,   8,   00,00,00,00,00,00,00,00,   DC
%     00071.148440,      0080,   0,   00,00,00,00,00,00,00,00,   ECU

txt = string(fileread(logFile));

pat = '(?m)^\s*([\d.]+),\s*([0-9A-Fa-f]+),\s*(\d+),\s*([0-9A-Fa-f]{2}(?:\s*,\s*[0-9A-Fa-f]{2}){7})\s*,';
tok = regexp(txt, pat, 'tokens');

n = numel(tok);
if n == 0
    trace = struct('Time',[],'ID',[],'DLC',[],'Data',uint8.empty(0,8));
    return
end

timesSec = zeros(n,1);
idHex    = strings(n,1);
dlc      = zeros(n,1);
dataStr  = strings(n,1);
for i = 1:n
    t = tok{i};
    timesSec(i) = str2double(t{1});
    idHex(i)    = t{2};
    dlc(i)      = str2double(t{3});
    dataStr(i)  = t{4};
end

id = hex2dec(cellstr(idHex));

Data = zeros(n,8,'uint8');
for i = 1:n
    % sscanf('%2x') stops at the first comma (it's not whitespace), which
    % would silently keep only byte 0 -- extract byte tokens explicitly.
    b = hex2dec(regexp(char(dataStr(i)), '[0-9A-Fa-f]{2}', 'match'));
    m = min(numel(b),8);
    Data(i,1:m) = uint8(b(1:m));
end
dlc = min(dlc,8);

t0 = timesSec(1);
trace.Time = timesSec - t0;   % already in seconds, relative to first frame
trace.ID   = id;
trace.DLC  = dlc;
trace.Data = Data;

end
