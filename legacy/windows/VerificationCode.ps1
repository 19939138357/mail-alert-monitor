Set-StrictMode -Version Latest

function ConvertTo-VerificationNormalText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # Normalize OCR width, horizontal spaces and quote shapes without changing offsets.
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Text.ToCharArray()) {
        $number = [int]$character
        if ($number -ge 0xFF01 -and $number -le 0xFF5E) {
            [void]$builder.Append([char]($number - 0xFEE0))
        }
        elseif ([char]::GetUnicodeCategory($character) -eq [System.Globalization.UnicodeCategory]::SpaceSeparator) {
            [void]$builder.Append(' ')
        }
        elseif ($number -in @(0x201C, 0x201D)) { [void]$builder.Append('"') }
        elseif ($number -in @(0x2018, 0x2019)) { [void]$builder.Append("'") }
        else { [void]$builder.Append($character) }
    }
    return $builder.ToString()
}

function Get-VerificationLabelPattern {
    return '(?i:确[ \t]*认[ \t]*码|验[ \t]*证[ \t]*码|动[ \t]*态[ \t]*码|校[ \t]*验[ \t]*码|(?<![A-Za-z0-9_])(?:OTP|verification[ \t]+code|security[ \t]+code|one[ -]*time[ \t]+(?:password|code))(?![A-Za-z0-9_]))'
}

function Get-VerificationCandidate {
    param([string]$Text, [int]$Offset = 0)

    # Keep a separate countdown field out of the code. A grouped code requires
    # a visible column gap (2+ spaces/tabs), so an ambiguous single-space run
    # such as "12 34 56 seconds" is still rejected rather than guessed.
    $countdown = [regex]::Match($Text, '^(?<code>[A-Za-z0-9]{4,8}|[0-9]{1,3}(?:[ \t]+[0-9]{1,3})+)(?<gap>[ \t]+)[0-9]{1,3}[ \t]*(?:秒(?:钟)?|分钟|小时|seconds?\b|minutes?\b|hours?\b)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($countdown.Success) {
        $codeText = $countdown.Groups['code'].Value
        if ($codeText -notmatch '[ \t]' -or $countdown.Groups['gap'].Length -ge 2) {
            return Get-VerificationCandidate -Text $codeText -Offset $Offset
        }
    }
    # Consume the entire token/run first: never truncate a phone number to 6 digits.
    $match = [regex]::Match($Text, '^(?:[0-9]+(?:[ \t]+[0-9]+)*|[A-Za-z0-9]+)')
    if (-not $match.Success) { return }
    # A numeric prefix of an alphanumeric code must be consumed as one token.
    if ($match.Length -lt $Text.Length -and $Text[$match.Length] -cmatch '[A-Za-z0-9]') {
        $match = [regex]::Match($Text, '^[A-Za-z0-9]+')
    }
    $raw = $match.Value
    $code = [regex]::Replace($raw, '[ \t]', '')
    if ($code.Length -lt 4 -or $code.Length -gt 8 -or $code -cnotmatch '[0-9]') { return }
    $kind = 'numeric'
    if ($code -cmatch '[A-Za-z]') { $kind = 'alphanumeric' }
    elseif ($raw -match '[ \t]') {
        $groups = @([regex]::Split($raw, '[ \t]+'))
        # 123 456 and 1 2 3 4 are grouped digits; 1234 5678 is ambiguous.
        if (@($groups | Where-Object { $_.Length -gt 3 }).Count -gt 0) { return }
    }

    $tail = $Text.Substring($match.Length)
    # Do not extract a valid-looking prefix from an email or unsupported token.
    if ($tail -match '^(?:[_@]|[-/.+][A-Za-z0-9])') { return }
    # Dates, ranges, quantities, countdowns and percent values are not codes.
    if ($tail -match '^[ \t]*(?:[-/.][ \t]*[0-9]|%|[年月日秒分时天个次条元位]|(?:seconds?|minutes?|hours?|digits?|times?)\b)') { return }
    [pscustomobject]@{ Code = $code; Kind = $kind; Index = $Offset; Length = $match.Length }
}

function Get-VerificationCodeMatches {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $normal = ConvertTo-VerificationNormalText -Text $Text
    $labels = [regex]::Matches($normal, (Get-VerificationLabelPattern))
    for ($labelIndex = 0; $labelIndex -lt $labels.Count; $labelIndex++) {
        $label = $labels[$labelIndex]
        $afterStart = $label.Index + $label.Length
        $afterEnd = [Math]::Min($normal.Length, $afterStart + 96)
        if ($labelIndex + 1 -lt $labels.Count) {
            $afterEnd = [Math]::Min($afterEnd, $labels[$labelIndex + 1].Index)
        }
        $after = $normal.Substring($afterStart, $afterEnd - $afterStart)
        # At most one line break between a label and its code; only known glue.
        $glue = [regex]::Match($after, '^[ \t:="''\[\]【】()<>《》]*(?:(?:为|是|为您|is\b)[ \t:="''\[\]【】()<>《》]*)?(?:(?:\([4-8][ \t]*位\)|[4-8][ \t]*位)[ \t:="''\[\]【】()<>《》]*)?(?:\r?\n[ \t:="''\[\]【】()<>《》]*)?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $candidate = Get-VerificationCandidate -Text $after.Substring($glue.Length) -Offset ($afterStart + $glue.Length)

        if ($null -ne $candidate) {
            $suffix = $normal.Substring($candidate.Index + $candidate.Length, $afterEnd - $candidate.Index - $candidate.Length)
            # A second adjacent candidate leaves this label unresolved.
            $alternative = [regex]::Match($suffix, '^[ \t,，/|、;；"''\[\]【】()<>《》]*(?:(?:或(?:者)?|or\b)[ \t:："''\[\]【】()<>《》]*)?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $other = Get-VerificationCandidate -Text $suffix.Substring($alternative.Length)
            if ($null -ne $other) { continue }
        }
        else {
            # Reverse wording must explicitly connect the code to this label.
            $beforeStart = [Math]::Max(0, $label.Index - 80)
            $before = $normal.Substring($beforeStart, $label.Index - $beforeStart)
            $reverse = [regex]::Match($before, '(?<![A-Za-z0-9_@./+-])(?<code>[A-Za-z0-9]+(?:[ \t]+[0-9]+)*)(?<glue>[ \t]+is[ \t]+(?:your[ \t]+|the[ \t]+)?|[ \t]*(?:是|为)(?:您|你)?的?[ \t]*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $reverse.Success) { continue }
            $codeGroup = $reverse.Groups['code']
            $candidate = Get-VerificationCandidate -Text $codeGroup.Value -Offset ($beforeStart + $codeGroup.Index)
            if ($null -eq $candidate) { continue }
            # Do not take the tail of a spaced phone number or one option of a list.
            $prefix = $before.Substring(0, $codeGroup.Index)
            $prefix = [regex]::Replace($prefix, '[ \t,，/|、;；]+$', '')
            $prefix = [regex]::Replace($prefix, '(?i:\bor|或(?:者)?)$', '')
            $prefix = [regex]::Replace($prefix, '[ \t,，/|、;；]+$', '')
            $previous = [regex]::Match($prefix, '(?<![A-Za-z0-9_@./+-])[A-Za-z0-9]+$')
            if ($previous.Success -and $null -ne (Get-VerificationCandidate -Text $previous.Value)) { continue }
        }
        $evidenceStart = [Math]::Min($label.Index, $candidate.Index)
        $evidenceEnd = [Math]::Max($afterStart, $candidate.Index + $candidate.Length)
        [pscustomobject]@{
            Code = [string]$candidate.Code
            Kind = [string]$candidate.Kind
            Evidence = $Text.Substring($evidenceStart, $evidenceEnd - $evidenceStart).Trim()
            Index = [int]$candidate.Index
            Length = [int]$candidate.Length
        }
    }
}

function Get-VerificationCodes {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($candidate in @(Get-VerificationCodeMatches -Text $Text)) {
        if ($seen.Add($candidate.Code)) {
            [pscustomobject]@{
                Code = [string]$candidate.Code
                Evidence = [string]$candidate.Evidence
                Kind = [string]$candidate.Kind
            }
        }
    }
}

function Protect-VerificationText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $normal = ConvertTo-VerificationNormalText -Text $Text
    $labels = [regex]::Matches($normal, (Get-VerificationLabelPattern))
    if ($labels.Count -eq 0) { return $Text }
    $spans = New-Object 'System.Collections.Generic.List[object]'
    foreach ($label in $labels) {
        $start = [Math]::Max(0, $label.Index - 80)
        $end = [Math]::Min($normal.Length, $label.Index + $label.Length + 96)
        $window = $normal.Substring($start, $end - $start)
        # Redaction is intentionally broader than extraction: hide ambiguous codes too.
        foreach ($match in [regex]::Matches($window, '(?<![A-Za-z0-9])[A-Za-z0-9]{4,8}(?![A-Za-z0-9])|(?<![A-Za-z0-9])[0-9]{1,3}(?:[ \t]+[0-9]{1,3})+(?![A-Za-z0-9])')) {
            $compact = [regex]::Replace($match.Value, '[ \t]', '')
            # A rejected long grouped run can still contain one or more real codes.
            # Redaction must not inherit extraction's 8-character upper bound.
            if ($compact.Length -ge 4 -and $compact -cmatch '[0-9]') {
                $spans.Add([pscustomobject]@{ Index = $start + $match.Index; Length = $match.Length })
            }
        }
    }
    if ($spans.Count -eq 0) { return $Text }
    # Merge overlaps caused by neighboring labels before replacing from right to left.
    $merged = New-Object 'System.Collections.Generic.List[object]'
    foreach ($span in @($spans | Sort-Object Index, Length)) {
        if ($merged.Count -gt 0) {
            $last = $merged[$merged.Count - 1]
            if ($span.Index -le $last.Index + $last.Length) {
                $last.Length = [Math]::Max($last.Index + $last.Length, $span.Index + $span.Length) - $last.Index
                continue
            }
        }
        $merged.Add([pscustomobject]@{ Index = $span.Index; Length = $span.Length })
    }
    $protected = $Text
    for ($index = $merged.Count - 1; $index -ge 0; $index--) {
        $span = $merged[$index]
        $protected = $protected.Remove($span.Index, $span.Length).Insert($span.Index, '[验证码已隐藏]')
    }
    return $protected
}
