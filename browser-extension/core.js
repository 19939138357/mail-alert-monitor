(function(root) {
  'use strict';
  const normalize = text => String(text || '').replace(/[\s\p{P}\p{S}]+/gu, '').toLowerCase();
  class Detector {
    constructor({keywords, stableScans = 2, maxSeen = 1000}) {
      this.keywords = keywords.map(k => ({name:k.name, terms:k.terms.map(normalize).filter(Boolean)}));
      this.stableScans = Math.max(2, stableScans); this.maxSeen = Math.max(1, maxSeen);
      this.seen = new Map(); this.previous = new Map(); this.candidates = new Map();
      this.initialized = false; this.sequence = 0;
    }
    scan(text) {
      if (!String(text || '').trim()) { this.candidates.clear(); this.previous = new Map(this.seen); return []; }
      const counts = new Map(), names = new Map();
      for (const line of String(text).split(/\r?\n/).map(s => s.trim()).filter(Boolean)) {
        if (/【夜间告警】|监控提醒|网页告警提醒|验证码提醒|推送测试|测试持续响铃/.test(line)) continue;
        const normalized = normalize(line);
        const match = this.keywords.find(k => k.terms.some(term => normalized.includes(term)));
        if (!match) continue;
        const key = match.name + '\t' + normalized;
        counts.set(key, (counts.get(key) || 0) + 1); names.set(key, match.name);
      }
      if (!this.initialized) {
        this.initialized = true;
        for (const [key, count] of counts) this.seen.set(key, count);
        this.previous = counts; this.prune(counts); return [];
      }
      const events = [];
      for (const [key, count] of counts) {
        const baseline = this.seen.get(key) || 0;
        let candidate = this.candidates.get(key);
        if (count <= baseline) candidate = null;
        else if (candidate && candidate.count === count) candidate.scans++;
        else candidate = {count, base:baseline, scans:1};
        if (candidate) {
          this.candidates.set(key, candidate);
          if (candidate.scans >= this.stableScans) {
            for (let i = candidate.base; i < count; i++) events.push({id:String(++this.sequence),keyword:names.get(key)});
            this.seen.set(key, count); this.candidates.delete(key);
          }
        } else this.candidates.delete(key);
      }
      for (const key of this.candidates.keys()) if (!counts.has(key)) this.candidates.delete(key);
      this.previous = counts; this.prune(counts); return events;
    }
    prune(current) {
      // Visible lines must remain remembered, even when the page exceeds maxSeen.
      for (const key of this.seen.keys()) {
        if (this.seen.size <= this.maxSeen) break;
        if (!current.has(key)) this.seen.delete(key);
      }
    }
  }
  const api = {Detector};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.BrowserAlertCore = api;
})(globalThis);
