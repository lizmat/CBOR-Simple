unit module CBOR::Simple:auth<zef:japhb>:api<0>:ver<0.0.3>;


enum CBORMajorType (
    CBOR_UInt  => 0,
    CBOR_NInt  => 1 +< 5,
    CBOR_BStr  => 2 +< 5,
    CBOR_TStr  => 3 +< 5,
    CBOR_Array => 4 +< 5,
    CBOR_Map   => 5 +< 5,
    CBOR_Tag   => 6 +< 5,
    CBOR_SVal  => 7 +< 5,
);


enum CBORMagicNumber (
    CBOR_MajorType_Mask => 0xE0,
    CBOR_Argument_Mask  => 0x1F,

    CBOR_False => 20,
    CBOR_True  => 21,
    CBOR_Null  => 22,
    CBOR_Undef => 23,

    CBOR_1Byte => 24,
    CBOR_2Byte => 25,
    CBOR_4Byte => 26,
    CBOR_8Byte => 27,

    CBOR_Indefinite_Break => 31,

    CBOR_Max_UInt_1Byte => 255,
    CBOR_Max_UInt_2Byte => 65535,
    CBOR_Max_UInt_4Byte => 4294967295,
    CBOR_Max_UInt_8Byte => 18446744073709551615,
    CBOR_Max_UInt_63Bit => 9223372036854775807,

    CBOR_Min_NInt_1Byte => -256,
    CBOR_Min_NInt_2Byte => -65536,
    CBOR_Min_NInt_4Byte => -4294967296,
    CBOR_Min_NInt_8Byte => -18446744073709551616,
);


enum CBORTagNumber (
    CBOR_Tag_DateTime_String => 0,
    CBOR_Tag_DateTime_Number => 1,
    CBOR_Tag_Unsigned_BigInt => 2,
    CBOR_Tag_Negative_BigInt => 3,
    CBOR_Tag_Rational        => 30,
);


# Break sentinel
my class Break { }


# Introspection of tagged values
class Tagged {
    has UInt:D $.tag-number is required;
    has Mu     $.value      is required;
    has Str:D  $.desc       =  '';
}


# Parsing exceptions
class X::Malformed is X::AdHoc {}

PROCESS::<$CBOR_SIMPLE_FATAL_ERRORS> = False;


# Precache a utf8 encoder, since we'll be doing it a LOT
my $utf8-encoder = Encoding::Registry.find("utf8").encoder;


# Don't use the RFC 8949 map key sorting, it's really slow
constant RFC8949_Map_Key_Sort = False;


# Encode an arbitrary value to CBOR
multi cbor-encode(Mu $value) is export {
    cbor-encode($value, my $pos = 0)
}

# Encode an arbitrary value to CBOR, specifying a buffer position to begin writing
multi cbor-encode(Mu $value, Int:D $pos is rw, Buf:D $buf = buf8.new) is export {
    my sub write-uint($major-type, $value) {
        if $value < CBOR_1Byte {
            $buf.write-uint8($pos++, $major-type + $value);
        }
        elsif $value <= CBOR_Max_UInt_1Byte {
            $buf.write-uint8($pos++, $major-type + CBOR_1Byte);
            $buf.write-uint8($pos++, $value);
        }
        elsif $value <= CBOR_Max_UInt_2Byte {
            $buf.write-uint8($pos++, $major-type + CBOR_2Byte);
            $buf.write-uint16($pos, $value, BigEndian);
            $pos += 2;
        }
        elsif $value <= CBOR_Max_UInt_4Byte {
            $buf.write-uint8($pos++, $major-type + CBOR_4Byte);
            $buf.write-uint32($pos, $value, BigEndian);
            $pos += 4;
        }
        elsif $value <= CBOR_Max_UInt_8Byte {
            $buf.write-uint8($pos++, $major-type + CBOR_8Byte);
            $buf.write-uint64($pos, $value, BigEndian);
            $pos += 8;
        }
    }

    # Defined values
    with $value {
        use nqp;
        # First classify by general role, then by actual type

        # Check for Numeric before Stringy so allomorphs prefer Numeric
        if nqp::istype($_, Numeric) {
            if nqp::istype($_, Bool) {
                $buf.write-uint8($pos++, CBOR_SVal + ($_ ?? CBOR_True !! CBOR_False));
            }
            elsif nqp::istype($_, Int) {
                if CBOR_Min_NInt_8Byte <= $_ <= CBOR_Max_UInt_8Byte {
                    $_ >= 0 ?? write-uint(CBOR_UInt,   $_)
                            !! write-uint(CBOR_NInt, +^$_);
                }
                # Unsigned BigInt
                elsif $_ >= 0 {
                    $buf.write-uint8($pos++, CBOR_Tag + CBOR_Tag_Unsigned_BigInt);
                    my @bytes = .polymod(256 xx *).reverse;
                    my $bytes = @bytes.elems;
                    write-uint(CBOR_BStr, $bytes);
                    $buf.splice($pos, $bytes, @bytes);
                    $pos += $bytes;
                }
                # Negative BigInt
                else {
                    $buf.write-uint8($pos++, CBOR_Tag + CBOR_Tag_Negative_BigInt);
                    my @bytes = (+^$_).polymod(256 xx *).reverse;
                    my $bytes = @bytes.elems;
                    write-uint(CBOR_BStr, $bytes);
                    $buf.splice($pos, $bytes, @bytes);
                    $pos += $bytes;
                }
            }
            elsif nqp::istype($_, Num) {
                # XXXX: Doesn't write short NaNs yet

                my num64 $num64 = $_;
                my num32 $num32 = $num64;
                # my num16 $num16 = $num64;

                my $use32 = $num32 == $num64 || $num64.isNaN && do {
                    my buf8 $nan .= new;
                    $nan.write-num64(0, $num64, BigEndian);
                    $nan[4] == $nan[5] == $nan[6] == $nan[7] == 0
                };

                # if $num16 == $num64 {
                #     # XXXX: write-num16 is UNAVAILABLE!
                #     die "Cannot write a 16-bit num";
                #
                #     $buf.write-uint8($pos++, CBOR_SVal + CBOR_2Byte);
                #     $buf.write-num16($pos, $num16, BigEndian);
                #
                #     # Canonify NaN sign bit to 0, even on platforms with -NaN
                #     $buf.write-uint8($pos, $buf.read-uint8($pos) +& 0x7F)
                #         if $num16.isNaN;
                #
                #     $pos += 2;
                # }
                if $use32 {
                    $buf.write-uint8($pos++, CBOR_SVal + CBOR_4Byte);
                    $buf.write-num32($pos, $num32, BigEndian);

                    # Canonify NaN sign bit to 0, even on platforms with -NaN
                    $buf.write-uint8($pos, $buf.read-uint8($pos) +& 0x7F)
                        if $num32.isNaN;

                    $pos += 4;
                }
                else {
                    $buf.write-uint8($pos++, CBOR_SVal + CBOR_8Byte);
                    $buf.write-num64($pos, $num64, BigEndian);

                    # Canonify NaN sign bit to 0, even on platforms with -NaN
                    $buf.write-uint8($pos, $buf.read-uint8($pos) +& 0x7F)
                        if $num64.isNaN;

                    $pos += 8;
                }
            }
            elsif nqp::istype($_, Rational) {
                # write-uint(CBOR_Tag, CBOR_Tag_Rational);
                $buf.write-uint8($pos++, CBOR_Tag + CBOR_1Byte);
                $buf.write-uint8($pos++, CBOR_Tag_Rational);
                $buf.write-uint8($pos++, CBOR_Array + 2);
                cbor-encode(.numerator,   $pos, $buf);
                cbor-encode(.denominator, $pos, $buf);
            }
            elsif nqp::istype($_, Instant) {
                my $num = .to-posix[0].Num;
                my $val = $num.Int == $num ?? $num.Int !! $num;

                $buf.write-uint8($pos++, CBOR_Tag + CBOR_Tag_DateTime_Number);
                cbor-encode($val, $pos, $buf);
            }
            elsif nqp::istype($_, Real) {
                # XXXX: Pretend any other Real is a Num
                cbor-encode(.Num, $pos, $buf);
            }
            else {
                my $ex = "Don't know how to encode a {$value.^name}";
                $*CBOR_SIMPLE_FATAL_ERRORS ?? die $ex !! fail $ex;
            }
        }
        elsif nqp::istype($_, Stringy) {
            if nqp::istype($_, Str) {
                my $utf8  = $utf8-encoder.encode-chars($_);
                my $bytes = $utf8.bytes;

                write-uint(CBOR_TStr, $bytes);
                $buf.splice($pos, $bytes, $utf8);
                $pos += $bytes;
            }
            elsif nqp::istype($_, Blob) {
                my $bytes = .bytes;

                write-uint(CBOR_BStr, $bytes);
                $buf.splice($pos, $bytes, $_);
                $pos += $bytes;
            }
            else {
                my $ex = "Don't know how to encode a {$value.^name}";
                $*CBOR_SIMPLE_FATAL_ERRORS ?? die $ex !! fail $ex;
            }
        }
        # XXXX: Seq/Iterator?
        elsif nqp::istype($_, Positional) {
            write-uint(CBOR_Array, .elems);
            cbor-encode($_, $pos, $buf) for @$_;
        }
        elsif nqp::istype($_, Associative) {
            write-uint(CBOR_Map, .elems);
            if RFC8949_Map_Key_Sort {
                my @pairs = .map: {
                    cbor-encode(.key, my $ = 0) => .value
                };
                @pairs.sort(*.key).map: {
                    my $bytes = .key.bytes;
                    $buf.splice($pos, $bytes, .key);
                    $pos += $bytes;
                    cbor-encode(.value, $pos, $buf);
                }
            }
            else {
                for .sort {
                    cbor-encode(.key,   $pos, $buf);
                    cbor-encode(.value, $pos, $buf);
                }
            }
        }
        elsif nqp::istype($_, Dateish) {
            if nqp::istype($_, DateTime) {
                my $num = .Instant.to-posix[0].Num;
                my $val = $num.Int == $num ?? $num.Int !! $num;

                $buf.write-uint8($pos++, CBOR_Tag + CBOR_Tag_DateTime_Number);
                cbor-encode($val, $pos, $buf);
            }
            else {
                $buf.write-uint8($pos++, CBOR_Tag + CBOR_Tag_DateTime_String);
                cbor-encode(.yyyy-mm-dd, $pos, $buf);
            }
        }
        else {
            my $ex = "Don't know how to encode a {$value.^name}";
            $*CBOR_SIMPLE_FATAL_ERRORS ?? die $ex !! fail $ex;
        }
    }
    # Undefined values
    else {
        # Any:U is CBOR null, other Mu:U is CBOR undefined
        $buf.write-uint8($pos++, CBOR_SVal + ($value ~~ Any ?? CBOR_Null !! CBOR_Undef));
    }

    $buf
}


# Decode the first value from CBOR-encoded data
multi cbor-decode(Blob:D $cbor) is export {
    my $value := cbor-decode($cbor, my $pos = 0);
    if $pos < $cbor.bytes {
        my $ex = X::Malformed.new(:payload("Extra data after decoded value"));
        $*CBOR_SIMPLE_FATAL_ERRORS ?? die $ex !! fail $ex;
    }
    $value
}

# Decode the next value from CBOR-encoded data, starting at $pos
multi cbor-decode(Blob:D $cbor, Int:D $pos is rw, Bool:D :$breakable = False) is export {
    my &fail-malformed = -> Str:D $reason {
        my $ex = X::Malformed.new(:payload($reason));
        $*CBOR_SIMPLE_FATAL_ERRORS ?? die $ex !! fail $ex;
    }

    CATCH {
        when /^ 'MVMArray: read_buf out of bounds' / {
            fail-malformed "Early end of input";
        }
        default { .rethrow }
    }

    my $argument;

    my &read-uint = -> $allow-indefinite = False {
        if $argument < CBOR_1Byte {
            $argument
        }
        elsif $argument == CBOR_1Byte {
            $cbor.read-uint8($pos++)
        }
        elsif $argument == CBOR_2Byte {
            my $v = $cbor.read-uint16($pos, BigEndian);
            $pos += 2;
            $v
        }
        elsif $argument == CBOR_4Byte {
            my $v = $cbor.read-uint32($pos, BigEndian);
            $pos += 4;
            $v
        }
        elsif $argument == CBOR_8Byte {
            my $v = $cbor.read-uint64($pos, BigEndian);
            $pos += 8;
            $v
        }
        elsif $argument == CBOR_Indefinite_Break {
            $allow-indefinite ?? Whatever
                              !! fail-malformed "Unexpected indefinite argument";
        }
        else {
            fail-malformed "Invalid argument $argument";
        }
    }

    my &decode = {
        my $initial-byte = $cbor.read-uint8($pos++);
        my $major-type   = $initial-byte +& CBOR_MajorType_Mask;
        $argument = $initial-byte +& CBOR_Argument_Mask;

        $major-type == CBOR_UInt ??   read-uint() !!
        $major-type == CBOR_NInt ?? +^read-uint() !!
        do if $major-type == CBOR_BStr {
            my $bytes = read-uint(!$breakable);

            # Indefinite length
            if $bytes === Whatever {
                my buf8 $joined .= new;
                until (my $chunk := cbor-decode($cbor, $pos, :breakable)) =:= Break {
                    fail-malformed "Byte string chunk has wrong type"
                        unless $chunk ~~ Buf:D;
                    $joined.append($chunk);
                }
                $joined
            }
            # Definite length
            else {
                fail-malformed "Unreasonably long byte string"
                    if $bytes > CBOR_Max_UInt_63Bit;

                my $buf = $cbor.subbuf($pos, $bytes);
                fail-malformed "Byte string too short" unless $buf.bytes == $bytes;
                $pos += $bytes;
                $buf
            }
        }
        elsif $major-type == CBOR_TStr {
            my $bytes = read-uint(!$breakable);

            # Indefinite length
            if $bytes === Whatever {
                my @chunks;
                until (my $chunk := cbor-decode($cbor, $pos, :breakable)) =:= Break {
                    fail-malformed "Text string chunk has wrong type"
                        unless $chunk ~~ Str:D;
                    @chunks.push($chunk);
                }
                @chunks.join
            }
            # Definite length
            else {
                fail-malformed "Unreasonably long text string"
                    if $bytes > CBOR_Max_UInt_63Bit;

                my $utf8 = $cbor.subbuf($pos, $bytes);
                fail-malformed "Text string too short" unless $utf8.bytes == $bytes;
                $pos += $bytes;
                $utf8.decode
            }
        }
        elsif $major-type == CBOR_Array {
            # Indefinite length
            $argument == CBOR_Indefinite_Break
            ?? do {
                my @array;
                until (my $item := cbor-decode($cbor, $pos, :breakable)) =:= Break {
                    @array.push($item);
                }
                @array
            }
            !! my @ = (^read-uint).map(&decode)
        }
        elsif $major-type == CBOR_Map {
            my %str-map;
            my %mu-map{Mu};

            # Indefinite length
            if $argument == CBOR_Indefinite_Break {
                loop {
                    my $k := cbor-decode($cbor, $pos, :breakable);
                    last if $k =:= Break;
                    ($k ~~ Str ?? %str-map !! %mu-map){$k} = decode;
                }
            }
            # Definite length
            else {
                ((my $k = decode) ~~ Str ?? %str-map !! %mu-map){$k} = decode
                    for ^read-uint;
            }

            if %mu-map.elems {
                %mu-map{$_} = %str-map{$_} for %str-map.keys;
                %mu-map
            }
            else {
                %str-map
            }
        }
        elsif $major-type == CBOR_Tag {
            my $tag-number = read-uint;
            if $tag-number == CBOR_Tag_DateTime_String {
                my $dt := cbor-decode($cbor, $pos);
                fail-malformed "DateTime tag (0) does not contain a string"
                    unless $dt ~~ Str:D;
                DateTime.new($dt) // fail-malformed "DateTime string could not be parsed"
            }
            elsif $tag-number == CBOR_Tag_DateTime_Number {
                my $seconds := cbor-decode($cbor, $pos);
                fail-malformed "Epoch DateTime tag(1) does not contain a real number"
                    unless $seconds ~~ Real:D;
                DateTime.new($seconds) // fail-malformed "Epoch DateTime could not be decoded"
            }
            elsif $tag-number == CBOR_Tag_Unsigned_BigInt {
                my $bytes := cbor-decode($cbor, $pos);
                fail-malformed "Unsigned BigInt does not contain a byte string"
                    unless $bytes ~~ Buf:D;
                my $value = 0;
                $value = $value * 256 + $_ for @$bytes;
                $value
            }
            elsif $tag-number == CBOR_Tag_Negative_BigInt {
                my $bytes := cbor-decode($cbor, $pos);
                fail-malformed "Negative BigInt does not contain a byte string"
                    unless $bytes ~~ Buf:D;
                my $value = 0;
                $value = $value * 256 + $_ for @$bytes;
                +^$value
            }

            # XXXX: skipped tags 4, 5, 16..18, 21..29

            elsif $tag-number == CBOR_Tag_Rational {
                fail-malformed "Rational tag (30) does not contain an array with exactly two elements"
                    unless $cbor.read-uint8($pos++) == CBOR_Array + 2;

                my $nu = decode;
                my $de = decode;
                fail-malformed "Rational tag (30) numerator is not an integer"
                    unless $nu ~~ Int:D;
                fail-malformed "Rational tag (30) denominator is not an unsigned integer"
                    unless $de ~~ UInt:D;

                $de < 18446744073709551616 ?? Rat.new(   $nu, $de)
                                           !! FatRat.new($nu, $de)
            }

            # XXXX: Handle more special tags

            else {
                Tagged.new(:$tag-number, :value(cbor-decode($cbor, $pos)))
            }
        }
        else { # $major-type == CBOR_SVal
            my constant %svals = 20 => False, 21 => True, 22 => Any, 23 => Mu;

            if $argument < CBOR_False {
                fail-malformed "Unassigned simple value $argument";
            }
            elsif $argument <= CBOR_Undef {
                %svals{$argument}
            }
            elsif $argument == CBOR_1Byte {
                my $val  = $cbor.read-uint8($pos++);
                my $fail = $val < 24 ?? "Badly formed" !!
                           $val < 32 ?? "Reserved"     !!
                                        "Unassigned"   ;
                fail-malformed "$fail simple value $val";
            }
            elsif $argument == CBOR_2Byte {
                # XXXX: read-num16 is UNAVAILABLE!
                die "Cannot read a 16-bit num";

                my $v = $cbor.read-num16($pos, BigEndian);
                $pos += 2;
                $v
            }
            elsif $argument == CBOR_4Byte {
                my $v = $cbor.read-num32($pos, BigEndian);
                $pos += 4;
                $v
            }
            elsif $argument == CBOR_8Byte {
                my $v = $cbor.read-num64($pos, BigEndian);
                $pos += 8;
                $v
            }
            elsif $argument == CBOR_Indefinite_Break {
                $breakable ?? Break
                           !! fail-malformed "Unexpected break signal";
            }
            else {
                fail-malformed "Badly formed simple value $argument";
            }
        }
    }

    decode;
}


# Convert a CBOR-encoded value to human diagnostic form
multi cbor-diagnostic(Blob:D $cbor) is export {
    cbor-diagnostic($cbor, my $pos = 0)
}

# Convert a CBOR-encoded value to human diagnostic form, starting at $pos
multi cbor-diagnostic(Blob:D $cbor, Int:D $pos is rw) is export {
    my $initial-byte = $cbor.read-uint8($pos++);
    my $major-type   = $initial-byte +& CBOR_MajorType_Mask;
    my $val          = $initial-byte +& CBOR_Argument_Mask;

    given $major-type {
        when CBOR_UInt {
            ...
        }
        when CBOR_NInt {
            ...
        }
        when CBOR_BStr {
            ...
        }
        when CBOR_TStr {
            ...
        }
        when CBOR_Array {
            ...
        }
        when CBOR_Map {
            ...
        }
        when CBOR_Tag {
            ...
        }
        when CBOR_SVal {
            ...
        }
    }
}


=begin pod

=head1 NAME

CBOR::Simple - Simple codec for the CBOR serialization format


=head1 SYNOPSIS

=begin code :lang<raku>

use CBOR::Simple;
my $cbor = cbor-encode($value);
my $val1 = cbor-decode($cbor);               # Fails if more data past first decoded value
my $val2 = cbor-decode($cbor, my $pos = 0);  # Updates $pos after decoding first value

# By default, cbor-decode() marks partially corrupt parsed structures with
# Failure nodes at the point of corruption
my $bad = cbor-decode(buf8.new(0x81 xx 3));  # [[[Failure]]]

# Callers can instead force throwing exceptions on any error
my $*CBOR_SIMPLE_FATAL_ERRORS = True;
my $bad = cbor-decode(buf8.new(0x81 xx 3));  # BOOM!

=end code


=head1 DESCRIPTION

CBOR::Simple is a trivial implementation of the core functionality of the
L<CBOR serialization format|https://cbor.io/>, implementing the standard as of
L<RFC 8949|https://tools.ietf.org/html/rfc8949>.

Currently known NOT to work:

=item 16-bit floats (num16)

=item Special decoding for registered tags other than numbers 0..3 and 30


=head2 SPECIAL CASES

=item CBOR's C<null> is translated as C<Any> in Raku

=item CBOR's C<undefined> is translated as C<Mu> in Raku

=item C<Instant> and C<DateTime> are both written as tag 1 (epoch-based date/time)

=item Both tag 0 (date/time string) and tag 1 (epoch-based date/time) are read as C<DateTime>

=item CBOR strings claiming to be longer than C<2⁶‭³‭-1> are treated as malformed


=head1 AUTHOR

Geoffrey Broadwell <gjb@sonic.net>


=head1 COPYRIGHT AND LICENSE

Copyright 2021 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.

=end pod
