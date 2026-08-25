function decoded = decodeMessages(trace, dbcMsgs)
%DECODEMESSAGES Decode every DBC signal present in a parsed trace.
%   decoded = DECODEMESSAGES(trace, dbcMsgs) returns a containers.Map keyed
%   by "MessageName.SignalName" -> struct with fields:
%       Time, Value  - Nx1 double vectors (physical units, DBC scaling applied)
%       Unit         - char
%       Message      - source message name
%       Signal       - signal name
%       MsgId        - decimal CAN ID
%       ValMap       - Nx2 cell {rawValue,label} enum table, or [] if none

decoded = containers.Map('KeyType','char','ValueType','any');

for m = 1:numel(dbcMsgs)
    msg = dbcMsgs(m);
    if isempty(msg.signals); continue; end
    rows = trace.ID == msg.id;
    if ~any(rows); continue; end

    subData = trace.Data(rows,:);
    subTime = trace.Time(rows);

    if msg.id == 960
        % Charger_informations (CAN ID 0x3C0) is multiplexed in the real
        % firmware (can_io.c, case 0x3c0) between THREE different sub-
        % messages selected by flag bits in byte 1 (RxData[1] & 0xC0):
        %   bit7 set        -> Ustopcharge/Outside_temp/Inside_temp (this DBC's layout)
        %   bit7 clr,bit6 set-> alarm/duration settings (not represented in this DBC)
        %   both clear      -> RTC time sync (hour/minute/second/...)
        % Decoding every frame as the first layout produced nonsense temps
        % (>200 C) whenever a time-sync or alarm frame slipped in. Keep
        % only the frames that are actually the temperature sub-message.
        isTempSubMsg = bitget(subData(:,2), 8) == 1;   % byte1 bit7 (MSB)
        subData = subData(isTempSubMsg,:);
        subTime = subTime(isTempSubMsg);

        % Firmware clears the top 2 bits of byte1 before using it as the
        % high byte of Ustopcharge ("RxData[1] &= ~0xc0;") -- those bits
        % are the multiplex flags just checked above, not data. Without
        % this, Ustopcharge's sign/value is corrupted by the flag bits.
        subData(:,2) = bitand(subData(:,2), uint8(63));
    end

    if msg.id == 658
        % ECU_Drive_mode_ECU_status (0x292): the FECU fault register is NOT
        % a contiguous little-endian 24-bit field in the real firmware
        % (can_io.c, case 0x292):
        %   ecu.errorMsg = (*(uint16_t*)&RxData[6]) | (RxData[5] << 16)
        % On this little-endian target that expands to
        %   errorMsg = RxData[6] | (RxData[7] << 8) | (RxData[5] << 16)
        % i.e. byte 5 is the MSB, byte 6 the LSB and byte 7 the middle byte
        % -- bytes 6 and 7 are swapped relative to a plain little-endian
        % 24-bit read. The DBC can't express that byte permutation as a
        % single signal, so it's reconstructed here directly from the raw
        % bytes instead of via a normal SG_. Decoding it as plain intel
        % little-endian (byte5|byte6<<8|byte7<<16, what the DBC used to
        % declare) silently produced the wrong fault code -- e.g. a real
        % 0x200000 (EMERGENCY BUTTON pressed) came out as 0x00020 (SKAI
        % Encoder Error).
        b5 = double(subData(:,6));
        b6 = double(subData(:,7));
        b7 = double(subData(:,8));
        fecuVal = b6 + b7*256 + b5*65536;

        entry.Time    = subTime;
        entry.Value   = fecuVal;
        entry.Unit    = '';
        entry.Message = msg.name;
        entry.Signal  = 'FECU_error';
        entry.MsgId   = msg.id;
        entry.ValMap  = [];
        decoded([msg.name '.FECU_error']) = entry;
    end

    if msg.id == 1030
        % BMS_Cell_voltage_and_temperature (0x406) is multiplexed per-cell
        % in the real firmware (can_io.c, case 0x406): each frame reports
        % ONE cell's voltage, selected by Cell_number ("if ((RxData[2] > 0)
        % && (RxData[2] < 37))", i.e. cells numbered 1-36, matching this
        % DBC's Cell_number/Cell_voltage bit layout exactly -- no correction
        % needed here, unlike several other messages (see PROJECT_NOTES.md).
        % Split the interleaved stream into 36 per-cell time series
        % (...Cell_voltage_01 .. _36) so the Cell Voltages bar-chart tab
        % (buildSignalGroups.m) can show all 36 cells side by side at the
        % scrubbed instant -- the generic per-signal decode below still
        % produces the raw interleaved Cell_number/Cell_voltage series too,
        % just not directly usable for a per-cell view on its own.
        sigCellNum = findSignalByName(msg, 'Cell_number');
        sigCellVal = findSignalByName(msg, 'Cell_voltage');
        if ~isempty(sigCellNum) && ~isempty(sigCellVal)
            cellNoRaw = double(decodeSignalRaw(subData, sigCellNum.startBit, sigCellNum.length, sigCellNum.byteOrder));
            voltRaw   = double(decodeSignalRaw(subData, sigCellVal.startBit, sigCellVal.length, sigCellVal.byteOrder));
            voltVal   = voltRaw * sigCellVal.factor + sigCellVal.offset;
            for cellN = 1:36
                rowsForCell = cellNoRaw == cellN;
                if ~any(rowsForCell); continue; end
                entry.Time    = subTime(rowsForCell);
                entry.Value   = voltVal(rowsForCell);
                entry.Unit    = sigCellVal.unit;
                entry.Message = msg.name;
                entry.Signal  = sprintf('Cell_voltage_%02d', cellN);
                entry.MsgId   = msg.id;
                entry.ValMap  = [];
                decoded([msg.name '.' entry.Signal]) = entry;
            end
        end
    end

    for s = 1:numel(msg.signals)
        sg = msg.signals(s);
        raw = double(decodeSignalRaw(subData, sg.startBit, sg.length, sg.byteOrder));

        if sg.signed
            half = 2^(sg.length-1);
            neg = raw >= half;
            raw(neg) = raw(neg) - 2^sg.length;
        end

        val = raw * sg.factor + sg.offset;

        entry.Time    = subTime;
        entry.Value   = val;
        entry.Unit    = sg.unit;
        entry.Message = msg.name;
        entry.Signal  = sg.name;
        entry.MsgId   = msg.id;
        entry.ValMap  = sg.valMap;

        key = [msg.name '.' sg.name];
        decoded(key) = entry;
    end
end

function sg = findSignalByName(msg, name)
sg = [];
for i = 1:numel(msg.signals)
    if strcmp(msg.signals(i).name, name)
        sg = msg.signals(i);
        return
    end
end
end

end
