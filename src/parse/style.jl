"""
    STACStyle()

The `JSON.JSONStyle` every `STAC.parse`, `STAC.read`, and [`STAC.json`](@ref) call passes to
JSON.jl. It contributes two things to StructUtils' machinery:

- an RFC 3339 `lift` for `DateTime`, accepting any number of fractional digits and both the
  `Z` and `±HH:MM` offset forms;
- `make` methods for the types this package owns, which route each key to a typed field, an
  extension slot, or the object's metadata tail in one forward pass (see `parse/sinks.jl`).
"""
struct STACStyle <: JSON.JSONStyle end

@noinline _badrfc3339(s) = throw(BadDateTime(String(s)))

@inline function _fixeddigits(b, i, w, s)
    v = 0
    n = length(b)
    for _ in 1:w
        (i <= n && UInt8('0') <= @inbounds(b[i]) <= UInt8('9')) || _badrfc3339(s)
        v = 10v + Int(@inbounds(b[i]) - UInt8('0'))
        i += 1
    end
    return v, i
end

@inline function _expectbyte(b, i, c::Char, s)
    (i <= length(b) && @inbounds(b[i]) == UInt8(c)) || _badrfc3339(s)
    return i + 1
end

"""
    STAC.parse_rfc3339(s::AbstractString) -> DateTime

An RFC 3339 date-time in UTC. Fractional seconds of any length are accepted and truncated to
the millisecond `DateTime` holds; `Z`, `z`, and `±HH:MM` offsets are all applied.

StructUtils' own ISO parser caps the fraction at three digits, which rejects the six-digit
timestamps Planetary Computer and the stac-spec examples carry.
"""
function parse_rfc3339(s::AbstractString)
    b = codeunits(s)
    n = length(b)
    y, i = _fixeddigits(b, 1, 4, s); i = _expectbyte(b, i, '-', s)
    mo, i = _fixeddigits(b, i, 2, s); i = _expectbyte(b, i, '-', s)
    d, i = _fixeddigits(b, i, 2, s)
    if i > n
        return DateTime(y, mo, d)
    end
    (@inbounds(b[i]) == UInt8('T') || @inbounds(b[i]) == UInt8('t') || @inbounds(b[i]) == UInt8(' ')) ||
        _badrfc3339(s)
    i += 1
    h, i = _fixeddigits(b, i, 2, s); i = _expectbyte(b, i, ':', s)
    mi, i = _fixeddigits(b, i, 2, s); i = _expectbyte(b, i, ':', s)
    sec, i = _fixeddigits(b, i, 2, s)
    ms = 0
    if i <= n && @inbounds(b[i]) == UInt8('.')
        i += 1
        digits = 0
        while i <= n && UInt8('0') <= @inbounds(b[i]) <= UInt8('9')
            digits < 3 && (ms = 10ms + Int(@inbounds(b[i]) - UInt8('0')))
            digits += 1
            i += 1
        end
        digits == 0 && _badrfc3339(s)
        while digits < 3
            ms *= 10
            digits += 1
        end
    end
    offsetmin = 0
    if i <= n
        c = @inbounds b[i]
        if c == UInt8('Z') || c == UInt8('z')
            i += 1
        elseif c == UInt8('+') || c == UInt8('-')
            i += 1
            oh, i = _fixeddigits(b, i, 2, s); i = _expectbyte(b, i, ':', s)
            om, i = _fixeddigits(b, i, 2, s)
            offsetmin = (c == UInt8('+') ? 1 : -1) * (60oh + om)
        else
            _badrfc3339(s)
        end
    end
    i == n + 1 || _badrfc3339(s)
    dt = DateTime(y, mo, d, h, mi, sec, ms)
    return offsetmin == 0 ? dt : dt - Minute(offsetmin)
end

StructUtils.lift(::STACStyle, ::Type{DateTime}, s::AbstractString) = (parse_rfc3339(s), nothing)

"""
    STAC.format_rfc3339(dt::DateTime) -> String

A `DateTime` as the UTC RFC 3339 string STAC requires, always ending in `Z` and carrying
milliseconds only when they are non-zero.
"""
function format_rfc3339(dt::DateTime)
    ms = Dates.millisecond(dt)
    base = string(Dates.format(dt, dateformat"yyyy-mm-dd\THH:MM:SS"))
    frac = ms == 0 ? "" : string(".", lpad(ms, 3, '0'))
    return string(base, frac, "Z")
end
