import React, { useEffect, useRef, useState } from 'react';
import {
  SafeAreaView, View, Text, TextInput, ScrollView, Pressable, StyleSheet,
} from 'react-native';
import { Meld, MeldWidget, type MeldStatus } from '@meldcrypto/react-native-sdk';
import { MELD_API_KEY, MELD_CUSTOMER_ID, MELD_API_HOST } from '@env';

// Credentials come from a gitignored .env (copy .env.example -> .env). ⚠️ POC ONLY — DO NOT
// SHIP: a real app creates the order on its backend so the API key never reaches the device;
// this example calls Meld directly just to stay self-contained.
const CONFIG = {
  apiKey: MELD_API_KEY,
  customerId: MELD_CUSTOMER_ID,
  apiHost: MELD_API_HOST || 'api-sb.meld.io', // e.g. api-qa.meld.io for QA
  version: '2026-05-01',
};

// Fixed corridor, same as the native demo: 15 USD -> BTC, US, Mercuryo card.
const ORDER = {
  sourceAmount: '15',
  sourceCurrencyCode: 'USD',
  destinationCurrencyCode: 'BTC',
  countryCode: 'US',
  defaultWallet: 'bc1qr74wmrcwqq9w5yxczxj6udts9mnqsh3xlhk5yp',
};

Meld.configure('sandbox'); // or 'production'

// The server-held customer id is preferred; show an input only when it isn't set.
const needsCustomerField = !CONFIG.customerId;

// X-Idempotency-Key must be a UUID (the backend parses it as one). RN/Hermes has no built-in
// uuid, so generate a v4 here (fine for a POC; use a real uuid lib in production).
function uuidv4(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

async function publicIP(): Promise<string | undefined> {
  try {
    const r = await fetch('https://api64.ipify.org?format=json');
    return (await r.json()).ip;
  } catch {
    return undefined;
  }
}

// POC stand-in for your backend — sets the Meld auth/version/idempotency headers.
function post(path: string, body: object): Promise<Response> {
  return fetch(`https://${CONFIG.apiHost}${path}`, {
    method: 'POST',
    headers: {
      Authorization: `BASIC ${CONFIG.apiKey}`,
      'Meld-Version': CONFIG.version,
      'X-Idempotency-Key': uuidv4(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}

async function fetchQuote(): Promise<{ destinationAmount?: number; totalFee?: number; exchangeRate?: number }> {
  const res = await post('/payments/crypto/quote?integrationMode=HEADLESS', {
    countryCode: ORDER.countryCode,
    sourceAmount: ORDER.sourceAmount,
    sourceCurrencyCode: ORDER.sourceCurrencyCode,
    destinationCurrencyCode: ORDER.destinationCurrencyCode,
    paymentMethodType: 'CREDIT_DEBIT_CARD',
    serviceProviders: ['MERCURYO'],
  });
  const json = await res.json();
  const q = (json.quotes || [])[0];
  if (!q) throw new Error(json.message || 'no quotes returned');
  return q;
}

async function createOrder(customerId: string, wallet: string): Promise<object> {
  const res = await post('/crypto/order/headless', {
    customerId,
    externalOrderId: `rn-demo-${Date.now()}`,
    sessionType: 'BUY',
    serviceProvider: 'MERCURYO',
    paymentMethodType: 'CREDIT_DEBIT_CARD',
    sourceCurrencyCode: ORDER.sourceCurrencyCode,
    sourceAmount: ORDER.sourceAmount,
    destinationCurrencyCode: ORDER.destinationCurrencyCode,
    destinationWalletAddress: wallet,
    countryCode: ORDER.countryCode,
    clientIpAddress: await publicIP(),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${json.code ?? res.status} — ${json.message ?? 'order creation failed'}`);
  return json;
}

// Trim trailing zeros so amounts read cleanly (0.00021400 -> 0.000214).
function format(n: number): string {
  let s = n.toFixed(8);
  while (s.includes('.') && (s.endsWith('0') || s.endsWith('.'))) s = s.slice(0, -1);
  return s;
}

// Status banner labels + colors — same as the web demo.
const BANNER: Record<MeldStatus, { title: string; sub: string; dot: string; bg: string; fg: string }> = {
  pending: { title: 'Processing payment…', sub: '', dot: '#8a93a3', bg: '#eef1f5', fg: '#3a4453' },
  completed: { title: 'Order complete', sub: 'Provider confirmed — settlement via webhook', dot: '#1c9c52', bg: '#e7f4ec', fg: '#1c7a43' },
  failed: { title: 'Order failed', sub: '', dot: '#d93b2b', bg: '#fbeae8', fg: '#b3261e' },
  cancelled: { title: 'Order cancelled', sub: '', dot: '#8a93a3', bg: '#eef1f5', fg: '#3a4453' },
};

function StatusBanner({ status }: { status: MeldStatus | null }) {
  if (!status) return null;
  const b = BANNER[status];
  return (
    <View style={[styles.banner, { backgroundColor: b.bg }]}>
      <View style={[styles.dot, { backgroundColor: b.dot }]} />
      <Text style={[styles.bannerTitle, { color: b.fg }]}>{b.title}</Text>
      {b.sub ? <Text style={styles.bannerSub}>{b.sub}</Text> : null}
    </View>
  );
}

const PRESETS = ['15', '50', '100', '250', '500'];

export default function App() {
  const [order, setOrder] = useState<object | null>(null);
  const [wallet, setWallet] = useState(ORDER.defaultWallet);
  const [customerId, setCustomerId] = useState('');
  const [receiveText, setReceiveText] = useState('…');
  const [quoteNote, setQuoteNote] = useState('fetching live quote…');
  const [rateText, setRateText] = useState('Credit / debit card rail');
  const [errorText, setErrorText] = useState('');
  const [busy, setBusy] = useState(false);
  const [lines, setLines] = useState<string[]>([]);
  const [status, setStatus] = useState<MeldStatus | null>(null);
  const closing = useRef(false);
  const logRef = useRef<ScrollView>(null);

  // On mount: fetch a live quote to display.
  useEffect(() => {
    (async () => {
      if (!CONFIG.apiKey) {
        setReceiveText('≈ —');
        setQuoteNote('MELD_API_KEY not set');
        setErrorText('MELD_API_KEY is empty. Fill .env (see README), then restart Metro with --reset-cache.');
        return;
      }
      try {
        const q = await fetchQuote();
        if (q.destinationAmount != null) setReceiveText(`≈ ${format(q.destinationAmount)}`);
        if (q.totalFee != null) setQuoteNote(`live quote — total fees ${format(q.totalFee)} ${ORDER.sourceCurrencyCode}`);
        if (q.exchangeRate != null) setRateText(`1 BTC ≈ ${Math.round(q.exchangeRate).toLocaleString()} ${ORDER.sourceCurrencyCode}`);
      } catch (e: any) {
        setReceiveText('≈ —');
        setQuoteNote(`quote failed: ${e.message}`);
      }
    })();
  }, []);

  const record = (line: string) => {
    console.log('[demo]', line);
    const t = new Date().toISOString().slice(11, 19);
    setLines((prev) => [...prev, `${t}  ${line}`]);
  };

  // demo-only: close once, shortly after a terminal event, so the outcome stays visible.
  const finish = (reason: string) => {
    if (closing.current) return;
    closing.current = true;
    record(`→ closing widget (${reason})`);
    setTimeout(() => setOrder(null), 1500);
  };

  const buy = async () => {
    setErrorText('');
    setBusy(true);
    try {
      const customer = needsCustomerField ? customerId.trim() : CONFIG.customerId;
      if (!customer) {
        setErrorText('Set a Meld customer ID.');
        return;
      }
      const created = await createOrder(customer, wallet.trim());
      setLines([]);
      setStatus(null);
      closing.current = false;
      setOrder(created);
    } catch (e: any) {
      setErrorText(e.message);
    } finally {
      setBusy(false);
    }
  };

  // ---- widget screen ----
  if (order) {
    return (
      <SafeAreaView style={styles.widgetPage}>
        <View style={styles.widgetBar}>
          <Text style={styles.back} onPress={() => setOrder(null)}>← Back</Text>
          <Text style={styles.widgetTitle}>Mercuryo</Text>
        </View>
        <MeldWidget
          style={styles.fill}
          order={order}
          onReady={() => record('onReady')}
          onPaymentSubmitted={() => record('onPaymentSubmitted (UX hint, not settled)')}
          onStatusChange={(e) => {
            setStatus(e.status);
            record(`onStatusChange: ${e.status} (${e.providerStatus ?? '-'})`);
            if (e.status === 'completed') finish('completed');
            if (e.status === 'failed') finish('failed');
          }}
          onCancel={() => { setStatus('cancelled'); record('onCancel'); finish('cancelled'); }}
          onError={(e) => { setStatus('failed'); record(`onError [${e.code}] ${e.message}`); finish('error'); }}
        />
        <View style={styles.logPanel}>
          <StatusBanner status={status} />
          <ScrollView
            ref={logRef}
            style={styles.log}
            contentContainerStyle={styles.logContent}
            onContentSizeChange={() => logRef.current?.scrollToEnd({ animated: true })}
          >
            {lines.length === 0
              ? <Text style={styles.logLine}>waiting for events…</Text>
              : lines.map((l, i) => <Text key={i} style={styles.logLine}>{l}</Text>)}
          </ScrollView>
        </View>
      </SafeAreaView>
    );
  }

  // ---- checkout screen (styled to match the web demo) ----
  const buyDisabled = busy || !wallet.trim();
  return (
    <SafeAreaView style={styles.page}>
      <ScrollView contentContainerStyle={styles.pageContent}>
        <View style={styles.card}>
          {/* header */}
          <View style={styles.hdr}>
            <Text style={styles.logo}>⬢</Text>
            <View style={styles.buyPill}><Text style={styles.buyPillText}>Buy</Text></View>
            <View style={styles.country}><Text>🇺🇸</Text><Text style={styles.countryText}>US</Text></View>
          </View>

          {/* you pay */}
          <View style={styles.panel}>
            <View style={styles.panelBody}>
              <View>
                <Text style={styles.panelLabel}>You pay</Text>
                <Text style={styles.amount}>{ORDER.sourceAmount}</Text>
              </View>
              <View style={styles.chip}><Text>🇺🇸</Text><Text style={styles.chipText}>{ORDER.sourceCurrencyCode}</Text></View>
            </View>
            <View style={styles.presets}>
              {PRESETS.map((p, i) => (
                <View key={p} style={[styles.preset, i < PRESETS.length - 1 && styles.presetDivider, p === ORDER.sourceAmount && styles.presetActive]}>
                  <Text style={[styles.presetText, p === ORDER.sourceAmount && styles.presetTextActive]}>{p}</Text>
                </View>
              ))}
            </View>
          </View>

          {/* you receive */}
          <View style={styles.panel}>
            <View style={styles.panelBody}>
              <View style={styles.flex1}>
                <Text style={styles.panelLabel}>You receive</Text>
                <Text style={styles.amount} numberOfLines={1} adjustsFontSizeToFit>{receiveText}</Text>
              </View>
              <View style={styles.chip}>
                <View style={styles.btcIcon}><Text style={styles.btcIconText}>₿</Text></View>
                <Text style={styles.chipText}>BTC</Text>
              </View>
            </View>
            <Text style={styles.sub}>{quoteNote}</Text>
            <View style={styles.quoteRow}>
              <Text style={styles.quoteBy}>By ✦ Mercuryo</Text>
              <Text style={styles.quoteMore}>{rateText}</Text>
            </View>
          </View>

          {/* wallet */}
          <Text style={styles.fieldLabel}>Wallet Address</Text>
          <TextInput style={styles.input} value={wallet} onChangeText={setWallet} autoCapitalize="none" autoCorrect={false} />

          {/* customer (only if not provided via .env) */}
          {needsCustomerField && (
            <>
              <Text style={styles.fieldLabel}>Meld Customer ID</Text>
              <TextInput style={styles.input} value={customerId} onChangeText={setCustomerId} autoCapitalize="none" autoCorrect={false} placeholder="customer with APPROVED KYC" />
            </>
          )}

          {/* payment method */}
          <Text style={styles.fieldLabel}>Payment Method</Text>
          <View style={styles.method}>
            <Text style={styles.methodIcon}>💳</Text>
            <Text style={styles.methodText}>Credit or debit card</Text>
          </View>

          {/* buy */}
          <Pressable style={[styles.cta, buyDisabled ? styles.ctaDisabled : styles.ctaReady]} disabled={buyDisabled} onPress={buy}>
            <Text style={[styles.ctaText, buyDisabled ? styles.ctaTextDisabled : styles.ctaTextReady]}>
              {busy ? 'Creating order…' : 'Buy Bitcoin'}
            </Text>
          </Pressable>

          {!!errorText && <Text style={styles.err}>{errorText}</Text>}

          <Text style={styles.footer}>Powered by <Text style={styles.footerBold}>Meld.io</Text></Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  flex1: { flex: 1 },

  // page + card
  page: { flex: 1, backgroundColor: '#2b2b28' },
  pageContent: { padding: 16, alignItems: 'center' },
  card: { width: '100%', maxWidth: 480, backgroundColor: '#f1f0ec', borderRadius: 18, padding: 18 },

  // header
  hdr: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 },
  logo: { fontSize: 26, color: '#15191f' },
  buyPill: { backgroundColor: '#3e6650', borderRadius: 10, paddingHorizontal: 24, paddingVertical: 7 },
  buyPillText: { color: '#fff', fontWeight: '700', fontSize: 15 },
  country: { flexDirection: 'row', alignItems: 'center', gap: 6, backgroundColor: '#fff', borderRadius: 10, paddingHorizontal: 12, paddingVertical: 7 },
  countryText: { fontSize: 14, color: '#15191f' },

  // amount panels
  panel: { backgroundColor: '#e6e5df', borderRadius: 12, marginBottom: 12, overflow: 'hidden' },
  panelBody: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 16 },
  panelLabel: { color: '#6b7280', fontSize: 15, marginBottom: 2 },
  amount: { fontSize: 38, fontWeight: '700', color: '#15191f' },
  chip: { flexDirection: 'row', alignItems: 'center', gap: 7, backgroundColor: '#fff', borderRadius: 12, paddingHorizontal: 12, paddingVertical: 9 },
  chipText: { fontWeight: '700', fontSize: 17, color: '#15191f' },
  btcIcon: { width: 22, height: 22, borderRadius: 11, backgroundColor: '#f7931a', alignItems: 'center', justifyContent: 'center' },
  btcIconText: { color: '#fff', fontWeight: '700', fontSize: 13 },
  sub: { color: '#6b7280', fontSize: 13, textAlign: 'right', paddingHorizontal: 16, paddingBottom: 10 },
  presets: { flexDirection: 'row', borderTopWidth: 1, borderTopColor: '#d7d6d0' },
  preset: { flex: 1, alignItems: 'center', paddingVertical: 11, backgroundColor: '#eceae5' },
  presetDivider: { borderRightWidth: 1, borderRightColor: '#d7d6d0' },
  presetActive: { backgroundColor: '#e0ded8' },
  presetText: { fontSize: 15, color: '#374151' },
  presetTextActive: { fontWeight: '700' },
  quoteRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', borderTopWidth: 1, borderTopColor: '#d7d6d0', backgroundColor: '#eceae5', paddingHorizontal: 16, paddingVertical: 12 },
  quoteBy: { color: '#15191f', fontSize: 15 },
  quoteMore: { color: '#374151', fontSize: 14 },

  // fields
  fieldLabel: { fontSize: 16, color: '#15191f', marginTop: 14, marginBottom: 6 },
  input: { borderWidth: 1.5, borderColor: '#d8d7d1', backgroundColor: '#f7f6f2', borderRadius: 12, paddingHorizontal: 14, paddingVertical: 14, fontSize: 15, color: '#15191f' },
  method: { flexDirection: 'row', alignItems: 'center', gap: 10, borderWidth: 1.5, borderColor: '#d8d7d1', backgroundColor: '#f7f6f2', borderRadius: 12, paddingHorizontal: 14, paddingVertical: 14 },
  methodIcon: { fontSize: 18 },
  methodText: { fontSize: 16, color: '#15191f' },

  // buy button
  cta: { marginTop: 20, borderRadius: 12, paddingVertical: 16, alignItems: 'center' },
  ctaReady: { backgroundColor: '#3e6650' },
  ctaDisabled: { backgroundColor: '#dcdad4' },
  ctaText: { fontSize: 18, fontWeight: '700' },
  ctaTextReady: { color: '#fff' },
  ctaTextDisabled: { color: '#9aa0a8' },
  err: { color: '#b3261e', fontSize: 13, marginTop: 10 },
  footer: { textAlign: 'center', color: '#374151', fontSize: 13, marginTop: 16 },
  footerBold: { color: '#15191f', fontWeight: '700' },

  // widget screen
  widgetPage: { flex: 1, backgroundColor: '#fff' },
  widgetBar: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 14, paddingVertical: 10 },
  back: { color: '#374151', fontSize: 15 },
  widgetTitle: { fontWeight: '600', fontSize: 15 },
  logPanel: { padding: 12, backgroundColor: '#f1f0ec' },
  banner: { flexDirection: 'row', alignItems: 'center', gap: 9, padding: 11, borderRadius: 10, marginBottom: 8 },
  dot: { width: 9, height: 9, borderRadius: 5 },
  bannerTitle: { fontSize: 14, fontWeight: '600' },
  bannerSub: { fontSize: 12, color: '#6b7280', flexShrink: 1 },
  log: { height: 120, backgroundColor: '#0b1220', borderRadius: 8 },
  logContent: { padding: 8 },
  logLine: { color: '#c8d3e8', fontFamily: 'Menlo', fontSize: 11 },
});
