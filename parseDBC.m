function msgs = parseDBC(dbcFile)
%PARSEDBC Parse a Vector DBC file into a struct array of messages/signals.
%   msgs = PARSEDBC(dbcFile) returns a struct array with fields:
%       id, name, dlc, sender, signals
%   where signals is itself a struct array with fields:
%       name, startBit, length, byteOrder ('intel'|'motorola'),
%       signed, factor, offset, min, max, unit, receivers, valMap
%   valMap is an Nx2 cell array {rawValue, label} or [] if none defined.

lines = splitlines(string(fileread(dbcFile)));

msgs = struct('id',{},'name',{},'dlc',{},'sender',{},'signals',{});
curMsgIdx = 0;

boPat  = '^BO_\s+(\d+)\s+([A-Za-z0-9_]+)\s*:\s*(\d+)\s+([A-Za-z0-9_]+)';
sgPat  = '^SG_\s+([A-Za-z0-9_]+)\s*(?:[Mm]\d*)?\s*:\s*(\d+)\|(\d+)@(\d)([+-])\s*\(([^,]+),([^)]+)\)\s*\[([^\|]*)\|([^\]]*)\]\s*"([^"]*)"\s*(.*)$';
valPat = '^VAL_\s+(\d+)\s+([A-Za-z0-9_]+)\s+(.*?);?\s*$';

for i = 1:numel(lines)
    ln = strtrim(lines(i));
    if ln == "" || startsWith(ln,";")
        continue
    end

    if startsWith(ln,"BO_ ")
        tok = regexp(ln, boPat, 'tokens', 'once');
        if isempty(tok); continue; end
        curMsgIdx = numel(msgs) + 1;
        msgs(curMsgIdx).id      = str2double(tok{1});
        msgs(curMsgIdx).name    = tok{2};
        msgs(curMsgIdx).dlc     = str2double(tok{3});
        msgs(curMsgIdx).sender  = tok{4};
        msgs(curMsgIdx).signals = struct('name',{},'startBit',{},'length',{}, ...
            'byteOrder',{},'signed',{},'factor',{},'offset',{}, ...
            'min',{},'max',{},'unit',{},'receivers',{},'valMap',{});

    elseif startsWith(ln,"SG_ ") && curMsgIdx > 0
        tok = regexp(ln, sgPat, 'tokens', 'once');
        if isempty(tok); continue; end
        s = struct();
        s.name      = tok{1};
        s.startBit  = str2double(tok{2});
        s.length    = str2double(tok{3});
        if tok{4} == "1"
            s.byteOrder = 'intel';
        else
            s.byteOrder = 'motorola';
        end
        s.signed    = (tok{5} == "-");
        s.factor    = str2double(tok{6});
        s.offset    = str2double(tok{7});
        s.min       = str2double(tok{8});
        s.max       = str2double(tok{9});
        s.unit      = tok{10};
        s.receivers = strtrim(tok{11});
        s.valMap    = [];
        n = numel(msgs(curMsgIdx).signals) + 1;
        msgs(curMsgIdx).signals(n) = s;
    end
end

% Second pass: attach VAL_ (enumerated value) tables to their signals
for i = 1:numel(lines)
    ln = strtrim(lines(i));
    if ~startsWith(ln,"VAL_ "); continue; end
    tok = regexp(ln, valPat, 'tokens', 'once');
    if isempty(tok); continue; end
    msgId  = str2double(tok{1});
    sigName = tok{2};
    rest   = tok{3};

    pairs = regexp(rest, '(-?\d+)\s*"([^"]*)"', 'tokens');
    if isempty(pairs); continue; end
    valMap = cell(numel(pairs),2);
    for k = 1:numel(pairs)
        valMap{k,1} = str2double(pairs{k}{1});
        valMap{k,2} = pairs{k}{2};
    end

    mIdx = find([msgs.id] == msgId, 1);
    if isempty(mIdx); continue; end
    sIdx = find(strcmp({msgs(mIdx).signals.name}, sigName), 1);
    if isempty(sIdx); continue; end
    msgs(mIdx).signals(sIdx).valMap = valMap;
end

end
