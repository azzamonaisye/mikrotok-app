import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- RouterOS API (البروتوكول الثنائي: المنفذ 8728 / 8729 مشفّر) ----------
class Trap {
  final String m;
  Trap(this.m);
  @override
  String toString() => m;
}

class Api {
  final String host, user, pass;
  final int port;
  final bool ssl;
  Api(this.host, this.port, this.user, this.pass, this.ssl);

  Socket? _s;
  StreamIterator<Uint8List>? _it;
  Uint8List _cur = Uint8List(0);
  int _pos = 0;
  Future<void> _last = Future.value();

  void _reset() {
    _s?.destroy();
    _s = null;
    _it = null;
    _cur = Uint8List(0);
    _pos = 0;
  }

  Future<bool> _fill() async {
    if (!await _it!.moveNext()) return false;
    _cur = _it!.current;
    _pos = 0;
    return true;
  }

  Future<int> _byte() async {
    while (_pos >= _cur.length) {
      if (!await _fill()) throw 'انقطع الاتصال بالراوتر';
    }
    return _cur[_pos++];
  }

  Future<int> _len() async {
    final b = await _byte();
    if (b < 0x80) return b;
    if (b < 0xC0) return ((b & 0x3F) << 8) | await _byte();
    if (b < 0xE0) {
      final b2 = await _byte(), b3 = await _byte();
      return ((b & 0x1F) << 16) | (b2 << 8) | b3;
    }
    if (b < 0xF0) {
      final b2 = await _byte(), b3 = await _byte(), b4 = await _byte();
      return ((b & 0x0F) << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    var r = 0;
    for (var i = 0; i < 4; i++) { r = (r << 8) | await _byte(); }
    return r;
  }

  Future<String> _word() async {
    final l = await _len();
    if (l == 0) return '';
    final out = Uint8List(l);
    var i = 0;
    while (i < l) {
      if (_pos >= _cur.length && !await _fill()) throw 'انقطع الاتصال بالراوتر';
      final k = min(l - i, _cur.length - _pos);
      out.setRange(i, i + k, _cur, _pos);
      _pos += k;
      i += k;
    }
    return utf8.decode(out, allowMalformed: true);
  }

  List<int> _enc(int l) {
    if (l < 0x80) return [l];
    if (l < 0x4000) { l |= 0x8000; return [l >> 8, l & 255]; }
    if (l < 0x200000) { l |= 0xC00000; return [l >> 16, (l >> 8) & 255, l & 255]; }
    if (l < 0x10000000) { l |= 0xE0000000; return [l >> 24, (l >> 16) & 255, (l >> 8) & 255, l & 255]; }
    return [0xF0, l >> 24, (l >> 16) & 255, (l >> 8) & 255, l & 255];
  }

  Future<List<Map<String, String>>> _exec(List<String> words) async {
    final b = BytesBuilder();
    for (final w in words) {
      final u = utf8.encode(w);
      b.add(_enc(u.length));
      b.add(u);
    }
    b.addByte(0);
    _s!.add(b.takeBytes());
    final rows = <Map<String, String>>[];
    String? trap;
    while (true) {
      final w = <String>[];
      while (true) {
        final x = await _word();
        if (x.isEmpty) break;
        w.add(x);
      }
      if (w.isEmpty) continue;
      final t = w[0];
      if (t == '!re') {
        final m = <String, String>{};
        for (final a in w.skip(1)) {
          if (!a.startsWith('=')) continue;
          final i = a.indexOf('=', 1);
          if (i > 0) m[a.substring(1, i)] = a.substring(i + 1);
        }
        rows.add(m);
      } else if (t == '!trap') {
        for (final a in w) {
          if (a.startsWith('=message=')) trap = a.substring(9);
        }
        trap ??= 'خطأ من الراوتر';
      } else if (t == '!fatal') {
        throw w.skip(1).join(' ');
      } else if (t == '!done') {
        if (trap != null) throw Trap(trap);
        return rows;
      }
    }
  }

  Future<void> _connect() async {
    _reset();
    const t = Duration(seconds: 6);
    _s = ssl
        ? await SecureSocket.connect(host, port, onBadCertificate: (_) => true, timeout: t)
        : await Socket.connect(host, port, timeout: t);
    _it = StreamIterator(_s!);
    try {
      await _exec(['/login', '=name=$user', '=password=$pass']).timeout(const Duration(seconds: 8));
    } catch (e) {
      _reset();
      throw (e is Trap ? 'فشل تسجيل الدخول: $e' : e);
    }
  }

  /// تنفيذ أمر، مثال: run(['/ip/hotspot/active/print'])
  Future<List<Map<String, String>>> run(List<String> words) {
    final c = Completer<List<Map<String, String>>>();
    final prev = _last;
    _last = c.future.then((_) {}, onError: (_) {});
    prev.then((_) async {
      try {
        if (_s == null) await _connect();
        c.complete(await _exec(words).timeout(const Duration(seconds: 10)));
      } catch (e) {
        if (e is! Trap) _reset();
        c.completeError(e);
      }
    });
    return c.future;
  }
}

late Api api;

String fmtB(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double v = b.toDouble();
  while (v >= 1024 && i < 4) { v /= 1024; i++; }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtR(num b) {
  const u = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  var i = 0;
  double v = b.toDouble();
  while (v >= 1000 && i < 3) { v /= 1000; i++; }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

num n(dynamic v) => num.tryParse('$v') ?? 0;

String fmtT(String? s) => (s ?? '')
    .replaceAllMapped(RegExp(r'(\d+)w'), (m) => '${m[1]}أسبوع ')
    .replaceAllMapped(RegExp(r'(\d+)d'), (m) => '${m[1]}ي ')
    .replaceAllMapped(RegExp(r'(\d+)h'), (m) => '${m[1]}س ')
    .replaceAllMapped(RegExp(r'(\d+)m'), (m) => '${m[1]}د ')
    .replaceAllMapped(RegExp(r'(\d+)s'), (m) => '${m[1]}ث');

Future<void> setDisabled(String name, bool dis) async {
  final v = dis ? 'yes' : 'no';
  Object? err;
  var ok = false;
  for (final p in ['/user-manager/user', '/ip/hotspot/user']) {
    try {
      final u = await api.run(['$p/print', '?name=$name']);
      if (u.isNotEmpty) {
        await api.run(['$p/set', '=.id=${u[0]['.id']}', '=disabled=$v']);
        ok = true;
      }
    } catch (e) { err = e; }
  }
  if (!ok && err != null) throw err;
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF1F5FD0),
            scaffoldBackgroundColor: const Color(0xFFEEF2F6)),
        home: const Boot(),
      );
}

class Boot extends StatefulWidget {
  const Boot({super.key});
  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> {
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final ip = p.getString('ip');
      Widget next = const Login();
      if (ip != null) {
        api = Api(ip, p.getInt('port') ?? 8728, p.getString('us') ?? '', p.getString('pw') ?? '', p.getBool('ssl') ?? false);
        next = const Shell();
      }
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => next));
    });
  }

  @override
  Widget build(BuildContext c) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class Login extends StatefulWidget {
  const Login({super.key});
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final ip = TextEditingController(), us = TextEditingController(text: 'admin'), pw = TextEditingController(), port = TextEditingController(text: '8728');
  bool https = false, busy = false;
  String err = '';

  Future<void> connect() async {
    setState(() { busy = true; err = ''; });
    final a = Api(ip.text.trim(), int.tryParse(port.text.trim()) ?? 8728, us.text.trim(), pw.text, https);
    try {
      await a.run(['/system/identity/print']);
      api = a;
      final p = await SharedPreferences.getInstance();
      await p.setString('ip', a.host);
      await p.setString('us', a.user);
      await p.setString('pw', a.pass);
      await p.setInt('port', a.port);
      await p.setBool('ssl', https);
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Shell()));
    } catch (e) {
      setState(() => err = 'تعذر الاتصال: $e');
    }
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const SizedBox(height: 30),
            const Text('الاتصال بالراوتر', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('يتصل عبر خدمة API في الراوتر (RouterOS 6.43 أو أحدث)'),
            const SizedBox(height: 16),
            TextField(controller: ip, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'عنوان الراوتر (مثل 192.168.88.1)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: port, keyboardType: TextInputType.number, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'منفذ API (الافتراضي 8728)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: us, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'اسم المستخدم', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: pw, obscureText: true, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'كلمة المرور', border: OutlineInputBorder())),
            SwitchListTile(title: const Text('اتصال مشفّر (api-ssl، عادةً المنفذ 8729)'), value: https, onChanged: (v) => setState(() { https = v; port.text = v ? '8729' : '8728'; })),
            FilledButton(onPressed: busy ? null : connect, child: Padding(padding: const EdgeInsets.all(12), child: Text(busy ? '...' : 'اتصال'))),
            if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(err, style: const TextStyle(color: Colors.red))),
          ]),
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;
  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(child: [const HomePage(), const ActivePage(), const UmPage()][i]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard), label: 'الرئيسية'),
            NavigationDestination(icon: Icon(Icons.wifi), label: 'المتصلون'),
            NavigationDestination(icon: Icon(Icons.people), label: 'يوزر منجر'),
          ],
        ),
      );
}

mixin Poll<T extends StatefulWidget> on State<T> {
  Timer? _t;
  String error = '';
  Future<void> load();
  Future<void> _safe() async {
    try { await load(); error = ''; } catch (e) { error = '$e'; }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _safe();
    _t = Timer.periodic(const Duration(seconds: 3), (_) => _safe());
  }

  void refresh() => _safe();
  @override
  void dispose() { _t?.cancel(); super.dispose(); }
}

Widget tile(String t, String v, Color col) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: const TextStyle(color: Colors.white70)),
        Text(v, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
      ]),
    );

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> with Poll {
  Map res = {}, clk = {}, id = {}, health = {}, tr = {};
  Map<String, String> cnt = {};
  String iface = 'ether1';

  @override
  Future<void> load() async {
    res = (await api.run(['/system/resource/print'])).first;
    id = (await api.run(['/system/identity/print'])).first;
    clk = (await api.run(['/system/clock/print'])).first;
    try {
      final h = await api.run(['/system/health/print']);
      health = {};
      for (final r in h) {
        if (r.containsKey('name')) { health[r['name']] = r['value']; } else { health.addAll(r); }
      }
    } catch (_) {}
    try {
      tr = (await api.run(['/interface/monitor-traffic', '=interface=$iface', '=once='])).first;
    } catch (_) {}
    for (final e in {'act': '/ip/hotspot/active', 'hs': '/ip/hotspot/user', 'um': '/user-manager/user', 'dh': '/ip/dhcp-server/lease'}.entries) {
      try {
        final a = await api.run(['${e.value}/print', '=.proplist=.id']);
        cnt[e.key] = '${a.length}';
      } catch (_) { cnt[e.key] = '–'; }
    }
  }

  @override
  Widget build(BuildContext c) {
    final tm = n(res['total-memory']), fm = n(res['free-memory']);
    final th = n(res['total-hdd-space']), fh = n(res['free-hdd-space']);
    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Text('${id['name'] ?? ''}  •  RouterOS ${res['version'] ?? ''}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 10),
        GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2, children: [
          tile('المعالج', '${res['cpu-load'] ?? '–'}%', const Color(0xFF1F5FD0)),
          tile('الفولت', '${health['voltage'] ?? '–'}', const Color(0xFF14997F)),
          tile('الحرارة °م', '${health['temperature'] ?? health['cpu-temperature'] ?? '–'}', const Color(0xFFCF4B32)),
          tile('مدة التشغيل', fmtT(res['uptime']), const Color(0xFFD69318)),
        ]),
        const SizedBox(height: 10),
        InkWell(
          onTap: () async {
            final tc = TextEditingController(text: iface);
            final v = await showDialog<String>(context: c, builder: (_) => AlertDialog(title: const Text('اسم الواجهة'), content: TextField(controller: tc), actions: [TextButton(onPressed: () => Navigator.pop(c, tc.text), child: const Text('حفظ'))]));
            if (v != null && v.isNotEmpty) { iface = v; refresh(); }
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF0E1B2C), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('سرعة النت • $iface (اضغط للتغيير)', style: const TextStyle(color: Colors.white70)),
              Text('↓ ${fmtR(n(tr['rx-bits-per-second']))}', textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
              Text('↑ ${fmtR(n(tr['tx-bits-per-second']))}', textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('الذاكرة'), Text('${fmtB(tm - fm)} / ${fmtB(tm)}')]),
          LinearProgressIndicator(value: tm == 0 ? 0 : (tm - fm) / tm),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('التخزين'), Text('${fmtB(th - fh)} / ${fmtB(th)}')]),
          LinearProgressIndicator(value: th == 0 ? 0 : (th - fh) / th),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('${res['board-name'] ?? ''}'), Text('${clk['date'] ?? ''} ${clk['time'] ?? ''}')]),
        ]))),
        GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.2, children: [
          tile('المتصلون هوتسبوت', cnt['act'] ?? '–', Colors.teal),
          tile('مستخدمو يوزر منجر', cnt['um'] ?? '–', Colors.indigo),
          tile('كروت هوتسبوت', cnt['hs'] ?? '–', Colors.deepPurple),
          tile('أجهزة DHCP', cnt['dh'] ?? '–', Colors.blueGrey),
        ]),
        TextButton(
          onPressed: () async {
            final p = await SharedPreferences.getInstance();
            await p.clear();
            if (c.mounted) Navigator.pushReplacement(c, MaterialPageRoute(builder: (_) => const Login()));
          },
          child: const Text('تسجيل الخروج'),
        ),
      ]),
    );
  }
}

class ActivePage extends StatefulWidget {
  const ActivePage({super.key});
  @override
  State<ActivePage> createState() => _ActiveState();
}

class _ActiveState extends State<ActivePage> with Poll {
  List<Map> list = [];
  String q = '', tab = 'all';

  @override
  Future<void> load() async {
    final h = await api.run(['/ip/hotspot/active/print']);
    List<Map<String, String>> p = [];
    try { p = await api.run(['/ppp/active/print']); } catch (_) {}
    list = [
      ...h.map((x) => {...x as Map, 'k': 'hs', 'n': x['user']}),
      ...p.map((x) => {...x as Map, 'k': 'ppp', 'n': x['name'], 'mac-address': x['caller-id']}),
    ];
  }

  @override
  Widget build(BuildContext c) {
    final L = list.where((x) => (tab == 'all' || x['k'] == tab) && '${x['n']} ${x['address']} ${x['mac-address']}'.toLowerCase().contains(q.toLowerCase())).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Wrap(spacing: 8, children: [
            for (final t in {'all': 'الكل', 'hs': 'هوتسبوت', 'ppp': 'PPP'}.entries)
              ChoiceChip(label: Text('${t.value} ${t.key == 'all' ? list.length : list.where((x) => x['k'] == t.key).length}'), selected: tab == t.key, onSelected: (_) => setState(() => tab = t.key)),
          ]),
          const SizedBox(height: 8),
          TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث: الكرت، IP، MAC', border: OutlineInputBorder(), filled: true, fillColor: Colors.white)),
          if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.red)),
        ]),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final x in L)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['n']}', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1F5FD0))),
              Text('${x['k'] == 'hs' ? 'هوتسبوت' : 'PPP'} • متصل ${fmtT(x['uptime'])}'),
              Text('تنزيل ${fmtB(n(x['bytes-out']))}   رفع ${fmtB(n(x['bytes-in']))}'),
              Text('IP ${x['address'] ?? ''}   MAC ${x['mac-address'] ?? ''}', textDirection: TextDirection.ltr),
              Row(children: [
                TextButton.icon(
                  icon: const Icon(Icons.link_off, color: Colors.red),
                  label: const Text('قطع', style: TextStyle(color: Colors.red)),
                  onPressed: () async {
                    try { await api.run(['${x['k'] == 'hs' ? '/ip/hotspot/active' : '/ppp/active'}/remove', '=.id=${x['.id']}']); refresh(); }
                    catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); }
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.block, color: Colors.orange),
                  label: const Text('تعطيل', style: TextStyle(color: Colors.orange)),
                  onPressed: () async {
                    try { await setDisabled('${x['n']}', true); refresh(); }
                    catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); }
                  },
                ),
              ]),
            ]))),
          if (L.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('لا يوجد متصلون حالياً.'))),
        ]),
      ),
    ]);
  }
}

class UmPage extends StatefulWidget {
  const UmPage({super.key});
  @override
  State<UmPage> createState() => _UmState();
}

class _UmState extends State<UmPage> with Poll {
  List list = [];
  String q = '';

  @override
  Future<void> load() async => list = await api.run(['/user-manager/user/print']);

  @override
  Widget build(BuildContext c) {
    final L = list.where((x) => '${x['name']}'.toLowerCase().contains(q.toLowerCase())).take(100).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث في مستخدمي يوزر منجر', border: OutlineInputBorder(), filled: true, fillColor: Colors.white)),
      ),
      if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.red)),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final x in L)
            Card(
              child: ListTile(
                title: Text('${x['name']}', textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1F5FD0))),
                subtitle: Text('${x['disabled'] == 'true' ? 'معطّل' : 'مفعّل'}  ${x['actual-profile'] ?? ''}  ${x['comment'] ?? ''}'),
                trailing: Switch(
                  value: x['disabled'] != 'true',
                  onChanged: (v) async {
                    try { await setDisabled('${x['name']}', !v); refresh(); }
                    catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); }
                  },
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}
