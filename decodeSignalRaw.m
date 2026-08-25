function raw = decodeSignalRaw(dataMatrix, startBit, len, byteOrder)
%DECODESIGNALRAW Extract the raw (unscaled) integer value of a DBC signal.
%   raw = DECODESIGNALRAW(dataMatrix, startBit, len, byteOrder) extracts the
%   bits for one signal from an Nx8 uint8 CAN data matrix, per the DBC bit
%   numbering convention. byteOrder is 'intel' (little-endian) or
%   'motorola' (big-endian). Returns an Nx1 uint64 raw value (sign
%   extension, factor and offset are applied separately).

n = size(dataMatrix,1);

if strcmp(byteOrder,'intel')
    % Combine the 8 bytes into one 64-bit little-endian value per row,
    % then the signal is a contiguous bitfield starting at startBit.
    msg = zeros(n,1,'uint64');
    for b = 1:8
        msg = bitor(msg, bitshift(uint64(dataMatrix(:,b)), (b-1)*8));
    end
    mask = bitshift(uint64(1), len) - uint64(1);
    raw = bitand(bitshift(msg, -startBit), mask);
else
    % Motorola/big-endian: bits are numbered in "sawtooth" order per byte
    % (byte b, bit 7..0 -> global index b*8+(7-bitInByte)). The signal's
    % bits run from startBit (MSB) to startBit+len-1 (LSB) in that order.
    raw = zeros(n,1,'uint64');
    for k = 0:len-1
        s = startBit + k;
        byteIdx = floor(s/8);
        bitInByte = 7 - mod(s,8);
        bitVal = bitget(dataMatrix(:,byteIdx+1), bitInByte+1);
        raw = bitor(bitshift(raw,1), uint64(bitVal));
    end
end

end
