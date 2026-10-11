#!/usr/bin/perl
# Blanks comments and string literals in Swift and Objective-C source so the source rules match
# code only, keeping line breaks so line numbers stay correct. Interpolations inside Swift strings
# (`\( ... )`) are kept, since they are code. Reads one file, writes to stdout.
use strict;
use warnings;

local $/;
my $text = <STDIN>;
my $out = '';
my $i = 0;
my $n = length $text;

sub blank_to {
    my ($end) = @_;
    while ($i < $end && $i < $n) {
        my $c = substr($text, $i, 1);
        $out .= $c eq "\n" ? "\n" : ' ';
        $i++;
    }
}

sub keep_to {
    my ($end) = @_;
    $out .= substr($text, $i, $end - $i);
    $i = $end;
}

sub skip_string {
    # $i is at the opening quote(s); $quote is `"` or `"""`.
    my ($quote) = @_;
    my $qlen = length $quote;
    blank_to($i + $qlen);
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '\\') {
            if (substr($text, $i + 1, 1) eq '(') {
                # Interpolation: keep its code up to the matching parenthesis.
                my $depth = 0;
                my $j = $i + 1;
                while ($j < $n) {
                    my $d = substr($text, $j, 1);
                    $depth++ if $d eq '(';
                    $depth-- if $d eq ')';
                    $j++;
                    last if $depth == 0;
                }
                blank_to($i + 1);
                keep_to($j);
                next;
            }
            blank_to($i + 2);
            next;
        }
        if (substr($text, $i, $qlen) eq $quote) {
            blank_to($i + $qlen);
            return;
        }
        blank_to($i + 1);
    }
}

while ($i < $n) {
    my $two = substr($text, $i, 2);
    if ($two eq '//') {
        my $eol = index($text, "\n", $i);
        $eol = $n if $eol < 0;
        blank_to($eol);
    } elsif ($two eq '/*') {
        my $depth = 0;
        my $j = $i;
        while ($j < $n) {
            my $pair = substr($text, $j, 2);
            if ($pair eq '/*') { $depth++; $j += 2; next; }
            if ($pair eq '*/') { $depth--; $j += 2; last if $depth == 0; next; }
            $j++;
        }
        blank_to($j);
    } elsif (substr($text, $i, 3) eq '"""') {
        skip_string('"""');
    } elsif (substr($text, $i, 1) eq '"') {
        skip_string('"');
    } elsif (substr($text, $i, 2) eq '@"') {
        blank_to($i + 1);
        skip_string('"');
    } elsif (substr($text, $i, 1) eq "'") {
        # Objective-C character literal.
        my $j = index($text, "'", $i + 1);
        $j = $i if $j < 0;
        blank_to($j + 1);
    } else {
        keep_to($i + 1);
    }
}
print $out;
