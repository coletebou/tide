use std::collections::HashMap;

/// A tide reading at a harbor.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading<'a> {
    pub harbor: &'a str,
    pub height_m: f32,
}

impl<'a> Reading<'a> {
    pub fn new(harbor: &'a str, height_m: f32) -> Self {
        Self { harbor, height_m }
    }
}

pub fn highest<'a>(readings: &[Reading<'a>]) -> HashMap<&'a str, f32> {
    let mut best = HashMap::new();
    for reading in readings {
        let entry = best.entry(reading.harbor).or_insert(f32::MIN);
        if reading.height_m > *entry {
            *entry = reading.height_m;
        }
    }
    println!("{} harbors", best.len());
    best
}
