//! Timestamp conversion without a date/time dependency.
//!
//! X returns `Wed Oct 10 20:19:24 +0000 2018`; the interface asks for
//! `YYYY-MM-DD HH:MM:SS +0000` in UTC. The civil-date conversion is Howard Hinnant's algorithm,
//! and the input variants are accepted defensively so a schema change does not lose the date.

pub(crate) fn format_x_date(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    parse_iso(raw)
        .or_else(|| parse_legacy(raw))
        .and_then(to_utc_string)
}

struct Parts {
    year: i64,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    /// Seconds east of UTC.
    offset: i64,
}

fn parse_iso(raw: &str) -> Option<Parts> {
    let (date, rest) = raw.split_once('T').or_else(|| raw.split_once(' '))?;
    let mut date_parts = date.split('-');
    let year = date_parts.next()?.parse::<i64>().ok()?;
    let month = date_parts.next()?.parse::<u32>().ok()?;
    let day = date_parts.next()?.parse::<u32>().ok()?;
    if date_parts.next().is_some() {
        return None;
    }

    let rest = rest.trim();
    let (time, offset_text) = match rest.split_once(' ') {
        Some((time, offset)) => (time, Some(offset.trim())),
        None => {
            // `20:19:24Z`, `20:19:24+08:00`, `20:19:24.123Z`: the first sign/Z after the
            // seconds starts the offset.
            let start = rest.find(':').unwrap_or(0).saturating_add(3);
            let idx = rest
                .char_indices()
                .skip_while(|(i, _)| *i < start)
                .find(|(_, c)| matches!(c, 'Z' | 'z' | '+' | '-'))
                .map(|(i, _)| i);
            match idx {
                Some(i) => (&rest[..i], Some(rest[i..].trim())),
                None => (rest, None),
            }
        }
    };
    let (hour, minute, second) = parse_hms(time)?;
    let offset = parse_offset(offset_text.unwrap_or("+00:00"))?;
    Some(Parts {
        year,
        month,
        day,
        hour,
        minute,
        second,
        offset,
    })
}

fn parse_legacy(raw: &str) -> Option<Parts> {
    // Wed Oct 10 20:19:24 +0000 2018
    let parts: Vec<&str> = raw.split_whitespace().collect();
    if parts.len() != 6 {
        return None;
    }
    let month = month_number(parts[1])?;
    let day = parts[2].parse::<u32>().ok()?;
    let (hour, minute, second) = parse_hms(parts[3])?;
    let offset = parse_offset(parts[4])?;
    let year = parts[5].parse::<i64>().ok()?;
    Some(Parts {
        year,
        month,
        day,
        hour,
        minute,
        second,
        offset,
    })
}

fn parse_hms(text: &str) -> Option<(u32, u32, u32)> {
    let mut parts = text.split(':');
    let hour = parts.next()?.parse::<u32>().ok()?;
    let minute = parts.next()?.parse::<u32>().ok()?;
    // Fractional seconds may follow; they do not change the displayed second.
    let second_text = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    let second = second_text.split(['.', ',']).next()?.parse::<u32>().ok()?;
    Some((hour, minute, second))
}

fn parse_offset(text: &str) -> Option<i64> {
    let text = text.trim();
    if text.eq_ignore_ascii_case("z") || text.eq_ignore_ascii_case("utc") {
        return Some(0);
    }
    let mut chars = text.chars();
    let sign = match chars.next()? {
        '+' => 1,
        '-' => -1,
        _ => return None,
    };
    let body = chars.as_str();
    // digits only from here (and slicing by byte below is then always on a character boundary)
    if !body.bytes().all(|b| b.is_ascii_digit() || b == b':') {
        return None;
    }
    let (hours, minutes) = if let Some((h, m)) = body.split_once(':') {
        (h, m)
    } else if body.len() == 4 {
        (&body[..2], &body[2..])
    } else if body.len() == 2 {
        (body, "0")
    } else {
        return None;
    };
    let hours = hours.parse::<i64>().ok()?;
    let minutes = minutes.parse::<i64>().ok()?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    Some(sign * (hours * 3600 + minutes * 60))
}

fn month_number(text: &str) -> Option<u32> {
    let text = text.to_ascii_lowercase();
    let text = text.trim_end_matches('.');
    Some(match text {
        "jan" => 1,
        "feb" => 2,
        "mar" => 3,
        "apr" => 4,
        "may" => 5,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "oct" => 10,
        "nov" => 11,
        "dec" => 12,
        _ => return None,
    })
}

fn to_utc_string(parts: Parts) -> Option<String> {
    if !(1..=9999).contains(&parts.year)
        || !(1..=12).contains(&parts.month)
        || parts.day == 0
        || parts.day > days_in_month(parts.year, parts.month)
        || parts.hour > 23
        || parts.minute > 59
        || parts.second > 60
        || parts.offset.abs() > 14 * 3600
    {
        return None;
    }
    let days = days_from_civil(parts.year, parts.month, parts.day);
    let seconds = days * 86_400
        + i64::from(parts.hour) * 3_600
        + i64::from(parts.minute) * 60
        + i64::from(parts.second)
        - parts.offset;
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    let (year, month, day) = civil_from_days(days);
    let hour = rest / 3_600;
    let minute = (rest % 3_600) / 60;
    let second = rest % 60;
    Some(format!(
        "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02} +0000"
    ))
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        _ => 0,
    }
}

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_prime = i64::from((month + 9) % 12);
    let day_of_year = (153 * month_prime + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let days = days + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    };
    (year + i64::from(month <= 2), month as u32, day as u32)
}

#[cfg(test)]
mod tests {
    #[test]
    fn offsets_never_panic_on_any_text() {
        for t in ["+😀", "+€a", "-ab:c", "+١٢٣٤", "+12:3€", "+", "", "+0530", "-08:00", "z"] { let _ = super::parse_offset(t); }
        assert_eq!(super::parse_offset("+0530"), Some(5 * 3600 + 30 * 60));
        assert_eq!(super::parse_offset("+€a"), None);
    }

    use super::*;

    #[test]
    fn converts_x_legacy_date() {
        assert_eq!(
            format_x_date("Wed Oct 10 20:19:24 +0000 2018").as_deref(),
            Some("2018-10-10 20:19:24 +0000")
        );
    }

    #[test]
    fn converts_non_utc_offsets() {
        assert_eq!(
            format_x_date("Wed Oct 10 20:19:24 -0700 2018").as_deref(),
            Some("2018-10-11 03:19:24 +0000")
        );
        assert_eq!(
            format_x_date("2018-10-10T20:19:24+08:00").as_deref(),
            Some("2018-10-10 12:19:24 +0000")
        );
    }

    #[test]
    fn accepts_target_and_iso_forms() {
        assert_eq!(
            format_x_date("2018-10-10 20:19:24 +0000").as_deref(),
            Some("2018-10-10 20:19:24 +0000")
        );
        assert_eq!(
            format_x_date("2018-10-10T20:19:24.123Z").as_deref(),
            Some("2018-10-10 20:19:24 +0000")
        );
    }

    #[test]
    fn leap_day() {
        assert_eq!(
            format_x_date("Thu Feb 29 00:00:00 +0000 2024").as_deref(),
            Some("2024-02-29 00:00:00 +0000")
        );
        assert_eq!(format_x_date("Wed Feb 29 00:00:00 +0000 2023"), None);
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(format_x_date("yesterday"), None);
        assert_eq!(format_x_date("Wed Foo 10 20:19:24 +0000 2018"), None);
        assert_eq!(format_x_date(""), None);
    }
}
