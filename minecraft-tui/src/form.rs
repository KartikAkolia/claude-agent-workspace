//! The settings editor. It only collects values: minecraft-twingate.sh update validates and
//! saves them, so a bad value fails there with the script's own message.

use crate::probe::Snapshot;

pub struct Field {
    pub label: &'static str,
    /// How the script takes it: a flag, or else an environment variable.
    flag: Option<&'static str>,
    env: &'static str,
    pub original: String,
    pub value: String,
}

pub struct Form {
    pub fields: Vec<Field>,
    pub selected: usize,
}

/// (label, the container's variable that shows the current value, the script's flag, else its
/// environment variable).
const FIELDS: [(&str, &str, Option<&str>, &str); 7] = [
    (
        "Minecraft version",
        "VERSION",
        Some("--version"),
        "MC_VERSION",
    ),
    ("Server type", "TYPE", Some("--type"), "MC_TYPE"),
    ("Java heap", "MEMORY", Some("--memory"), "MC_MEMORY"),
    ("Difficulty", "DIFFICULTY", None, "MC_DIFFICULTY"),
    ("Max players", "MAX_PLAYERS", None, "MC_MAX_PLAYERS"),
    ("MOTD", "MOTD", None, "MC_MOTD"),
    ("Operators", "OPS", None, "MC_OPS"),
];

/// The script's update arguments and environment for the changed fields, and a summary.
pub struct Changes {
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub summary: Vec<String>,
}

impl Form {
    pub fn new(snap: Option<&Snapshot>) -> Self {
        let fields = FIELDS
            .iter()
            .map(|&(label, key, flag, env)| {
                let current = snap.map_or("", |s| s.setting(key)).to_string();
                Field {
                    label,
                    flag,
                    env,
                    original: current.clone(),
                    value: current,
                }
            })
            .collect();
        Self {
            fields,
            selected: 0,
        }
    }

    pub fn field(&mut self) -> &mut Field {
        &mut self.fields[self.selected]
    }

    pub fn move_by(&mut self, step: isize) {
        let n = self.fields.len() as isize;
        self.selected = (self.selected as isize + step).rem_euclid(n) as usize;
    }

    /// The changes to apply. Only Operators may be emptied: the script reads an empty value of
    /// any other setting as "keep the saved one" (or refuses an empty flag).
    pub fn changes(&self) -> Result<Changes, String> {
        let mut out = Changes {
            args: vec!["update".into()],
            env: Vec::new(),
            summary: Vec::new(),
        };
        for f in self.fields.iter().filter(|f| f.value != f.original) {
            if f.value.trim().is_empty() && f.env != "MC_OPS" {
                return Err(format!("{} can't be empty.", f.label));
            }
            match f.flag {
                Some(flag) => out.args.extend([flag.to_string(), f.value.clone()]),
                None => out.env.push((f.env.to_string(), f.value.clone())),
            }
            out.summary.push(format!(
                "{}: {} -> {}",
                f.label,
                show(&f.original),
                show(&f.value)
            ));
        }
        Ok(out)
    }

    #[cfg(test)]
    fn set(&mut self, label: &str, value: &str) {
        let f = self.fields.iter_mut().find(|f| f.label == label).unwrap();
        f.value = value.into();
    }
}

fn show(v: &str) -> &str {
    if v.is_empty() { "(none)" } else { v }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_changed_fields_are_passed() {
        let mut form = Form::new(None);
        assert_eq!(form.changes().unwrap().args, ["update"]);
        assert!(form.changes().unwrap().summary.is_empty());
        form.set("Minecraft version", "26.3");
        form.set("MOTD", "Hello all");
        let c = form.changes().unwrap();
        assert_eq!(c.args, ["update", "--version", "26.3"]);
        assert_eq!(c.env, [("MC_MOTD".to_string(), "Hello all".to_string())]);
        assert_eq!(c.summary.len(), 2);
        form.set("Java heap", " ");
        assert!(form.changes().is_err(), "an emptied heap is refused");
        form.set("Java heap", "");
        // Emptying Operators is real: it clears the list.
        form.fields.last_mut().unwrap().original = "KA2314".into();
        let c = form.changes().unwrap();
        assert!(c.env.contains(&("MC_OPS".to_string(), String::new())));
        form.move_by(-1);
        assert_eq!(form.selected, FIELDS.len() - 1);
    }
}
