//! Byte-bounded LRU: hash lookup plus ordered recency, without full-cache scans.
use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

struct Entry<V> {
    value: V,
    bytes: usize,
    touched: u64,
    expires: Instant,
}

pub(crate) struct WeightedCache<V> {
    entries: HashMap<String, Entry<V>>,
    order: BTreeMap<u64, String>,
    clock: u64,
    bytes: usize,
    max_bytes: usize,
    max_entries: usize,
    ttl: Duration,
}

impl<V> WeightedCache<V> {
    pub fn new(max_bytes: usize, max_entries: usize, ttl: Duration) -> Self {
        Self {
            entries: HashMap::new(),
            order: BTreeMap::new(),
            clock: 0,
            bytes: 0,
            max_bytes,
            max_entries,
            ttl,
        }
    }

    fn tick(&mut self) -> u64 {
        if self.clock == u64::MAX {
            self.clear();
        }
        self.clock += 1;
        self.clock
    }

    fn remove(&mut self, key: &str) {
        if let Some(entry) = self.entries.remove(key) {
            self.order.remove(&entry.touched);
            self.bytes -= entry.bytes;
        }
    }

    pub fn get(&mut self, key: &str) -> Option<&V> {
        if self.entries.get(key)?.expires <= Instant::now() {
            self.remove(key);
            return None;
        }
        let tick = self.tick();
        let entry = self.entries.get_mut(key)?;
        self.order.remove(&entry.touched);
        self.order.insert(tick, key.to_owned());
        entry.touched = tick;
        Some(&entry.value)
    }

    pub fn insert(&mut self, key: String, value: V, payload_bytes: usize) {
        // Account for both key copies as well as the media payload.
        let bytes = payload_bytes.saturating_add(key.len().saturating_mul(2));
        self.remove(&key);
        if bytes > self.max_bytes || self.max_entries == 0 {
            return;
        }
        let tick = self.tick();
        while self.bytes > self.max_bytes - bytes || self.entries.len() >= self.max_entries {
            let Some((_, oldest)) = self.order.first_key_value() else {
                break;
            };
            let oldest = oldest.clone();
            self.remove(&oldest);
        }
        self.bytes += bytes;
        self.order.insert(tick, key.clone());
        self.entries.insert(
            key,
            Entry {
                value,
                bytes,
                touched: tick,
                expires: Instant::now() + self.ttl,
            },
        );
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
        self.bytes = 0;
        self.clock = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn byte_budget_evicts_cold_entries_and_preserves_hot_entries() {
        let mut cache = WeightedCache::new(16, 4, Duration::from_secs(10));
        cache.insert("a".into(), 1, 4);
        cache.insert("b".into(), 2, 4);
        assert_eq!(cache.get("a"), Some(&1));
        cache.insert("c".into(), 3, 4);
        assert!(cache.get("b").is_none());
        assert_eq!(cache.get("a"), Some(&1));
        assert!(cache.bytes <= 16);
        cache.insert("a".into(), 4, 20);
        assert!(cache.get("a").is_none());
        assert_eq!(cache.bytes, 6);
    }
    #[test]
    fn expired_values_and_counter_overflow_cannot_return_stale_entries() {
        let mut cache = WeightedCache::new(64, 2, Duration::ZERO);
        cache.insert("a".into(), 1, 2);
        assert!(cache.get("a").is_none());
        assert_eq!(cache.bytes, 0);
        cache.clock = u64::MAX;
        cache.insert("b".into(), 2, 2);
        assert_eq!(cache.order.len(), 1);
    }
}
