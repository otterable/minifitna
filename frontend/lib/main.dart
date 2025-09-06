// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:fl_chart/fl_chart.dart';

/// Simple logging facade to honor "logging.debug(...)" requirement.
class logging {
  static void debug(Object? msg) {
    // ignore: avoid_print
    print("[DEBUG] $msg");
  }
}

Future<void> _initTimezone() async {
  logging.debug("_initTimezone() start, kIsWeb=$kIsWeb");
  if (kIsWeb) {
    logging.debug("_initTimezone(): web -> skip tz init");
    return;
  }
  try {
    tzdata.initializeTimeZones();
    logging.debug("_initTimezone(): timezones initialized");
    tz.setLocalLocation(tz.getLocation('Europe/Vienna'));
    logging.debug("_initTimezone(): setLocalLocation('Europe/Vienna')");
  } catch (e) {
    logging.debug("_initTimezone(): error=$e, fallback to UTC");
    try {
      tz.setLocalLocation(tz.getLocation('UTC'));
    } catch (e2) {
      logging.debug("_initTimezone(): UTC fallback failed error=$e2");
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  logging.debug("main(): WidgetsFlutterBinding.ensureInitialized()");
  await _initTimezone();
  await NotificationService.instance.init();
  // Start frontend heartbeat early
  HeartbeatService.instance.start();
  logging.debug("main(): runApp");
  runApp(const MyApp());
}

/// Use Nginx origin (no :8743 in the frontend).
/// Switch to https://minifitna.ermine.at once TLS is active.
const String kBaseUrl = "http://minifitna.ermine.at";

class ApiService {
  final String _base = kBaseUrl;
  String? _jwt;
  final Duration _timeout = const Duration(seconds: 15);
  final http.Client _client = http.Client();

  static final ApiService instance = ApiService._();
  ApiService._();

  Future<void> loadToken() async {
    logging.debug("ApiService.loadToken() start");
    final sp = await SharedPreferences.getInstance();
    _jwt = sp.getString("jwt");
    logging.debug("ApiService.loadToken() jwt_present=${_jwt != null}");
  }

  Future<void> saveToken(String token) async {
    logging.debug("ApiService.saveToken() saving token len=${token.length}");
    final sp = await SharedPreferences.getInstance();
    _jwt = token;
    await sp.setString("jwt", token);
    logging.debug("ApiService.saveToken() done");
  }

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{"Accept": "application/json"};
    if (json) h["Content-Type"] = "application/json"; // don’t set for GET to avoid preflight
    if (_jwt != null) h["Authorization"] = "Bearer $_jwt";
    logging.debug("ApiService._headers(json=$json) -> $h");
    return h;
  }

  Future<Map<String, dynamic>> ping() async {
    final url = "$_base/api/ping";
    logging.debug("GET $url");
    final r = await _client.get(Uri.parse(url), headers: _headers()).timeout(_timeout);
    logging.debug("GET $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("ping: ${r.statusCode}");
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> register(String username, String password) async {
    final url = "$_base/api/register";
    final body = {"username": username, "password": password};
    logging.debug("POST $url body=$body");
    final r = await _client
        .post(Uri.parse(url), headers: _headers(json: true), body: jsonEncode(body))
        .timeout(_timeout);
    logging.debug("POST $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) {
      throw Exception("Register failed: ${r.body}");
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final url = "$_base/api/login";
    final body = {"username": username, "password": password};
    logging.debug("POST $url body=$body");
    final r = await _client
        .post(Uri.parse(url), headers: _headers(json: true), body: jsonEncode(body))
        .timeout(_timeout);
    logging.debug("POST $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) {
      throw Exception("Login failed: ${r.body}");
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> meGet() async {
    final url = "$_base/api/me";
    logging.debug("GET $url");
    final r = await _client.get(Uri.parse(url), headers: _headers()).timeout(_timeout);
    logging.debug("GET $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("meGet: ${r.body}");
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> meUpdate({
    required double targetWeight,
    required double dailyRunKm,
    required String weighTime,
    required String runTime,
  }) async {
    final url = "$_base/api/me";
    final body = {
      "target_weight": targetWeight,
      "daily_run_km": dailyRunKm,
      "weigh_time": weighTime,
      "run_time": runTime
    };
    logging.debug("PUT $url body=$body");
    final r = await _client
        .put(Uri.parse(url), headers: _headers(json: true), body: jsonEncode(body))
        .timeout(_timeout);
    logging.debug("PUT $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("meUpdate: ${r.body}");
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> weightsList({String? start, String? end}) async {
    final qp = {if (start != null) "start": start, if (end != null) "end": end};
    final uri = Uri.parse("$_base/api/weights").replace(queryParameters: qp);
    logging.debug("GET $uri");
    final r = await _client.get(uri, headers: _headers()).timeout(_timeout);
    logging.debug("GET $uri status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("weightsList: ${r.body}");
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<void> weightUpsert({required String day, required double weightKg}) async {
    final url = "$_base/api/weights";
    final body = {"day": day, "weight_kg": weightKg};
    logging.debug("POST $url body=$body");
    final r = await _client
        .post(Uri.parse(url), headers: _headers(json: true), body: jsonEncode(body))
        .timeout(_timeout);
    logging.debug("POST $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("weightUpsert: ${r.body}");
  }

  Future<List<dynamic>> runsList({String? start, String? end}) async {
    final qp = {if (start != null) "start": start, if (end != null) "end": end};
    final uri = Uri.parse("$_base/api/runs").replace(queryParameters: qp);
    logging.debug("GET $uri");
    final r = await _client.get(uri, headers: _headers()).timeout(_timeout);
    logging.debug("GET $uri status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("runsList: ${r.body}");
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<void> runUpsert({
    required String day,
    required double distanceKm,
    required double durationMin,
  }) async {
    final url = "$_base/api/runs";
    final body = {"day": day, "distance_km": distanceKm, "duration_min": durationMin};
    logging.debug("POST $url body=$body");
    final r = await _client
        .post(Uri.parse(url), headers: _headers(json: true), body: jsonEncode(body))
        .timeout(_timeout);
    logging.debug("POST $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("runUpsert: ${r.body}");
  }

  Future<Map<String, dynamic>> summary() async {
    final url = "$_base/api/summary";
    logging.debug("GET $url");
    final r = await _client.get(Uri.parse(url), headers: _headers()).timeout(_timeout);
    logging.debug("GET $url status=${r.statusCode} body=${_preview(r.body)}");
    if (r.statusCode >= 400) throw Exception("summary: ${r.body}");
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  String _preview(String body) {
    if (body.length <= 300) return body;
    return body.substring(0, 300) + "...(truncated)";
  }
}

/// Frontend heartbeat: pings /api/ping every 10s and exposes status.
class HeartbeatService {
  HeartbeatService._();
  static final HeartbeatService instance = HeartbeatService._();

  final ValueNotifier<bool> up = ValueNotifier<bool>(false);
  Timer? _timer;
  int _n = 0;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) async {
      _n++;
      logging.debug("HEARTBEAT #$_n -> ApiService.ping()");
      try {
        final res = await ApiService.instance.ping();
        logging.debug("HEARTBEAT #$_n ok: $res");
        if (!up.value) up.value = true;
      } catch (e) {
        logging.debug("HEARTBEAT #$_n error: $e");
        if (up.value) up.value = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Future<bool>? _boot;

  @override
  void initState() {
    super.initState();
    logging.debug("MyApp.initState()");
    _boot = _bootstrap();
  }

  Future<bool> _bootstrap() async {
    try {
      logging.debug("MyApp._bootstrap(): load token");
      await ApiService.instance.loadToken();
      logging.debug("MyApp._bootstrap(): try meGet for scheduling");
      try {
        final me = await ApiService.instance.meGet();
        logging.debug("MyApp._bootstrap(): me=$me");
        await NotificationService.instance.rescheduleBoth(me["weigh_time"], me["run_time"]);
      } catch (e) {
        logging.debug("MyApp._bootstrap(): meGet failed or not logged in -> $e");
      }
      logging.debug("MyApp._bootstrap(): done");
      return true;
    } catch (e) {
      logging.debug("MyApp._bootstrap(): error -> $e");
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("MyApp.build()");
    return MaterialApp(
      title: 'Run & Weight Coach',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: FutureBuilder<bool>(
        future: _boot,
        builder: (ctx, snap) {
          logging.debug("MyApp FutureBuilder: state=${snap.connectionState} hasData=${snap.hasData}");
          if (snap.connectionState != ConnectionState.done) {
            return Scaffold(
              appBar: AppBar(title: const Text("Run & Weight Coach"), actions: const [BackendStatusDot()]),
              body: const Center(child: CircularProgressIndicator()),
            );
          }
          return const Gate();
        },
      ),
    );
  }
}

/// Small colored dot for backend status in the AppBars.
class BackendStatusDot extends StatelessWidget {
  const BackendStatusDot({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: ValueListenableBuilder<bool>(
        valueListenable: HeartbeatService.instance.up,
        builder: (context, up, _) {
          final color = up ? Colors.green : Colors.red;
          final tooltip = up ? "Backend: UP" : "Backend: DOWN";
          return Tooltip(
            message: tooltip,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          );
        },
      ),
    );
  }
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  Future<bool> _loggedIn() async {
    logging.debug("Gate._loggedIn() start");
    final sp = await SharedPreferences.getInstance();
    final token = sp.getString("jwt");
    final res = token != null && token.isNotEmpty;
    logging.debug("Gate._loggedIn() -> $res");
    return res;
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("Gate.build()");
    return FutureBuilder<bool>(
      future: _loggedIn(),
      builder: (ctx, snap) {
        logging.debug("Gate FutureBuilder: state=${snap.connectionState} data=${snap.data}");
        if (!snap.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text("Run & Weight Coach"), actions: const [BackendStatusDot()]),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        return snap.data! ? const Home() : const AuthScreen();
      },
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _userC = TextEditingController();
  final _passC = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _do(bool register) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final user = _userC.text.trim();
    final pass = _passC.text;
    logging.debug("AuthScreen._do(register=$register) start user=$user");
    if (user.isEmpty || pass.isEmpty) {
      setState(() {
        _busy = false;
        _err = "Please enter username and password.";
      });
      logging.debug("AuthScreen._do(): missing credentials");
      return;
    }
    try {
      final api = ApiService.instance;
      final data = register ? await api.register(user, pass) : await api.login(user, pass);
      logging.debug("AuthScreen._do() response=$data");
      await api.saveToken(data["token"]);
      final me = await api.meGet();
      logging.debug("AuthScreen._do() me=$me");
      await NotificationService.instance.rescheduleBoth(me["weigh_time"], me["run_time"]);
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Home()));
      }
    } catch (e) {
      logging.debug("AuthScreen._do() error=$e");
      setState(() {
        _err = e.toString();
      });
    } finally {
      setState(() {
        _busy = false;
      });
      logging.debug("AuthScreen._do() end");
    }
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("AuthScreen.build()");
    return Scaffold(
      appBar: AppBar(title: const Text("Run & Weight Coach"), actions: const [BackendStatusDot()]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            elevation: 0,
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                Text("Sign in or Register", style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                TextField(controller: _userC, decoration: const InputDecoration(prefixIcon: Icon(Icons.person), labelText: "Username")),
                const SizedBox(height: 8),
                TextField(controller: _passC, obscureText: true, decoration: const InputDecoration(prefixIcon: Icon(Icons.lock), labelText: "Password")),
                const SizedBox(height: 12),
                if (_err != null) Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _do(false),
                      child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text("Login"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _do(true),
                      child: const Text("Register"),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;
  Map<String, dynamic>? _summary;
  bool _loading = true;

  Future<void> _load() async {
    logging.debug("Home._load() start");
    setState(() {
      _loading = true;
    });
    try {
      _summary = await ApiService.instance.summary();
      logging.debug("Home._load() summary=$_summary");
    } catch (e) {
      logging.debug("Home._load() error=$e");
    } finally {
      setState(() {
        _loading = false;
      });
      logging.debug("Home._load() end");
    }
  }

  @override
  void initState() {
    super.initState();
    logging.debug("Home.initState()");
    _load();
  }

  void _onSaved() {
    logging.debug("Home._onSaved()");
    _load();
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("Home.build() tab=$_tab loading=$_loading");
    final tabs = [
      _Dashboard(summary: _summary, loading: _loading, onRefresh: _load),
      LogScreen(onSaved: _onSaved),
      const HistoryScreen(),
      SettingsScreen(onSaved: () async {
        logging.debug("Home.Settings.onSaved() trigger");
        final me = await ApiService.instance.meGet();
        await NotificationService.instance.rescheduleBoth(me["weigh_time"], me["run_time"]);
        _load();
      }),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text("Run & Weight Coach"), actions: const [BackendStatusDot()]),
      body: tabs[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          logging.debug("Home.onDestinationSelected($i)");
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: "Dashboard"),
          NavigationDestination(icon: Icon(Icons.edit_outlined), selectedIcon: Icon(Icons.edit), label: "Log"),
          NavigationDestination(icon: Icon(Icons.history), label: "History"),
          NavigationDestination(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  final Map<String, dynamic>? summary;
  final bool loading;
  final Future<void> Function() onRefresh;
  const _Dashboard({required this.summary, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    logging.debug("_Dashboard.build() loading=$loading summary_present=${summary != null}");
    if (loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Weights & Prediction section (now persists goal date)
          const WeightsSection(),
          const SizedBox(height: 16),

          if (summary == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text("No summary yet. Log your first weight and run!"),
              ),
            )
          else ...[
            _metricCard(
              context,
              icon: Icons.monitor_weight,
              title: "Latest weight",
              value: summary!["latest_weight"] == null
                  ? "—"
                  : "${(summary!["latest_weight"] as num).toStringAsFixed(1)} kg",
              subtitle: (summary!["delta_to_target"] == null)
                  ? "Set your target in Settings"
                  : ((summary!["delta_to_target"] as num) > 0
                      ? "${(summary!["delta_to_target"] as num).toStringAsFixed(1)} kg above target"
                      : "${(summary!["delta_to_target"] as num).abs().toStringAsFixed(1)} kg below target"),
            ),
            const SizedBox(height: 12),
            _metricCard(
              context,
              icon: Icons.directions_run,
              title: "Run last 7 days",
              value: "${(summary!["run_7d_km"] as num).toStringAsFixed(1)} km",
              subtitle: "Daily goal: ${(summary!["daily_run_goal_km"] as num).toStringAsFixed(1)} km",
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _streakCard(context, "Weigh streak", summary!["weigh_streak"] as int)),
                const SizedBox(width: 12),
                Expanded(child: _streakCard(context, "Run streak", summary!["run_streak"] as int)),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text("Refresh"),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(BuildContext ctx, {required IconData icon, required String title, required String value, required String subtitle}) {
    logging.debug("_Dashboard._metricCard(title=$title, value=$value)");
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CircleAvatar(radius: 28, child: Icon(icon, size: 30)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(value, style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(ctx).textTheme.bodyMedium),
            ]),
          )
        ]),
      ),
    );
  }

  Widget _streakCard(BuildContext ctx, String label, int streak) {
    logging.debug("_Dashboard._streakCard(label=$label, streak=$streak)");
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.local_fire_department, size: 28),
            const SizedBox(width: 8),
            Text("$streak days", style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          ]),
        ]),
      ),
    );
  }
}

/// Section that loads weights, draws a chart, and provides goal predictor UI.
class WeightsSection extends StatefulWidget {
  const WeightsSection({super.key});
  @override
  State<WeightsSection> createState() => _WeightsSectionState();
}

class _WeightsSectionState extends State<WeightsSection> {
  static const String _goalDatePrefKey = "goal_target_date";

  bool _loading = true;
  List<_Point> _points = [];
  double? _slopePerDay; // negative = losing
  double? _intercept;
  DateTime? _baseDay; // x = days since baseDay
  String? _err;
  DateTime _targetDate = DateTime.now().add(const Duration(days: 30));
  final TextEditingController _targetWeightC = TextEditingController(text: "");
  double? _latestWeight;

  @override
  void initState() {
    super.initState();
    logging.debug("WeightsSection.initState()");
    _loadSavedGoalDate(); // NEW: restore persisted goal date
    _load();
  }

  Future<void> _loadSavedGoalDate() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString(_goalDatePrefKey);
      if (s != null) {
        final d = DateTime.parse(s);
        setState(() => _targetDate = d);
        logging.debug("WeightsSection._loadSavedGoalDate() loaded=$_targetDate");
      } else {
        logging.debug("WeightsSection._loadSavedGoalDate() none saved");
      }
    } catch (e) {
      logging.debug("WeightsSection._loadSavedGoalDate() error=$e");
    }
  }

  Future<void> _saveGoalDate() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_goalDatePrefKey, _targetDate.toIso8601String());
      logging.debug("WeightsSection._saveGoalDate() saved=$_targetDate");
    } catch (e) {
      logging.debug("WeightsSection._saveGoalDate() error=$e");
    }
  }

  Future<void> _load() async {
    logging.debug("WeightsSection._load() start");
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final weights = await ApiService.instance.weightsList();
      logging.debug("WeightsSection._load() got ${weights.length} weights");
      if (weights.isEmpty) {
        setState(() {
          _points = [];
          _slopePerDay = null;
          _intercept = null;
          _baseDay = null;
          _latestWeight = null;
          _loading = false;
        });
        return;
      }

      // Parse & sort ascending by day
      final parsed = <Map<String, dynamic>>[];
      for (final w in weights) {
        parsed.add({
          "day": DateTime.parse(w["day"] as String),
          "kg": (w["weight_kg"] as num).toDouble(),
        });
      }
      parsed.sort((a, b) => (a["day"] as DateTime).compareTo(b["day"] as DateTime));

      final base = parsed.first["day"] as DateTime;
      final pts = <_Point>[];
      for (final r in parsed) {
        final d = r["day"] as DateTime;
        final x = d.difference(base).inDays.toDouble();
        final y = (r["kg"] as double);
        pts.add(_Point(x: x, y: y, day: d));
      }

      final latest = parsed.last["kg"] as double;

      final reg = _linearRegression(pts);
      logging.debug("WeightsSection._load() regression slope_per_day=${reg?.m} intercept=${reg?.b} base=$base latest=$latest");

      // If targetWeight initial empty: default to current target (if available) or latest
      if (_targetWeightC.text.isEmpty) {
        try {
          final me = await ApiService.instance.meGet();
          final tw = (me["target_weight"] as num).toDouble();
          _targetWeightC.text = tw.toStringAsFixed(1);
        } catch (e) {
          _targetWeightC.text = latest.toStringAsFixed(1);
        }
      }

      setState(() {
        _points = pts;
        _slopePerDay = reg?.m;
        _intercept = reg?.b;
        _baseDay = base;
        _latestWeight = latest;
        _loading = false;
      });
    } catch (e) {
      logging.debug("WeightsSection._load() error=$e");
      setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
    logging.debug("WeightsSection._load() end");
  }

  _LinRegResult? _linearRegression(List<_Point> pts) {
    if (pts.length < 2) return null;
    double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
    for (final p in pts) {
      sumX += p.x;
      sumY += p.y;
      sumXY += p.x * p.y;
      sumXX += p.x * p.x;
    }
    final n = pts.length.toDouble();
    final denom = (n * sumXX - sumX * sumX);
    if (denom == 0) return null;
    final m = (n * sumXY - sumX * sumY) / denom;
    final b = (sumY - m * sumX) / n;
    return _LinRegResult(m: m, b: b);
  }

  double? _predictOn(DateTime date) {
    if (_slopePerDay == null || _intercept == null || _baseDay == null) return null;
    final x = date.difference(_baseDay!).inDays.toDouble();
    final y = _slopePerDay! * x + _intercept!;
    logging.debug("WeightsSection._predictOn(${date.toIso8601String()}) -> $y");
    return y;
  }

  bool? _goalFeasible(double targetWeight, DateTime targetDate) {
    if (_latestWeight == null) return null;
    final days = targetDate.difference(DateTime.now()).inDays;
    if (days <= 0) return null;
    final requiredDaily = (targetWeight - _latestWeight!) / days;
    final slope = _slopePerDay ?? 0.0;
    logging.debug("goalFeasible: latest=$_latestWeight target=$targetWeight days=$days requiredDaily=$requiredDaily slope=$slope");

    // Direction must align
    if (requiredDaily == 0 && slope.abs() < 0.01) return true;
    if (requiredDaily.sign != slope.sign && slope.abs() > 0.01) return false;

    // If our current magnitude is sufficient (allow 20% cushion), it's green.
    if (slope.abs() >= (requiredDaily.abs() * 0.8)) return true;

    // Otherwise red.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("WeightsSection.build() loading=$_loading err_present=${_err != null} points=${_points.length}");
    if (_loading) {
      return const Card(child: SizedBox(height: 220, child: Center(child: CircularProgressIndicator())));
    }
    if (_err != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text("Error loading weights: $_err"),
        ),
      );
    }
    if (_points.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            "No weights yet. Add your first weight in the Log tab to see your trend and predictions.",
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final base = _baseDay!;
    final minY = _points.map((p) => p.y).reduce(math.min);
    final maxY = _points.map((p) => p.y).reduce(math.max);
    final yPadding = (maxY - minY).clamp(1.0, 10.0);
    final viewMinY = (minY - yPadding * 0.5);
    final viewMaxY = (maxY + yPadding * 0.5);

    // Build predicted future line for next 30 days
    final futureDays = 30;
    final lastX = _points.last.x;
    final predLine = <FlSpot>[];
    if (_slopePerDay != null && _intercept != null) {
      for (int i = 0; i <= futureDays; i++) {
        final x = lastX + i.toDouble();
        final y = _slopePerDay! * x + _intercept!;
        predLine.add(FlSpot(x, y));
      }
    }

    // Real data line
    final realLine = _points.map((p) => FlSpot(p.x, p.y)).toList();

    String _fmtDateTick(double x) {
      final d = base.add(Duration(days: x.round()));
      return DateFormat('MM/dd').format(d);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Weight trend & 30-day projection", style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                SizedBox(
                  height: 260,
                  child: LineChart(
                    LineChartData(
                      minY: viewMinY,
                      maxY: viewMaxY,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((s) {
                              final d = base.add(Duration(days: s.x.round()));
                              final label = DateFormat('MMM d').format(d);
                              return LineTooltipItem("$label\n${s.y.toStringAsFixed(1)} kg", theme.textTheme.bodyMedium!);
                            }).toList();
                          },
                        ),
                      ),
                      gridData: const FlGridData(show: true),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (v, m) => Text("${v.toStringAsFixed(0)}", style: theme.textTheme.bodySmall),
                            interval: ((viewMaxY - viewMinY) / 4).clamp(1, 10).toDouble(),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            getTitlesWidget: (v, m) => Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_fmtDateTick(v), style: theme.textTheme.bodySmall),
                            ),
                            interval: (_points.length / 5).clamp(1, 7).toDouble(),
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: true),
                      lineBarsData: [
                        LineChartBarData(
                          spots: realLine,
                          isCurved: false,
                          dotData: const FlDotData(show: false),
                          barWidth: 3,
                        ),
                        if (predLine.isNotEmpty)
                          LineChartBarData(
                            spots: predLine,
                            isCurved: false,
                            dotData: const FlDotData(show: false),
                            barWidth: 2,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _slopePerDay == null
                      ? "Trend: not enough data."
                      : (_slopePerDay! < 0
                          ? "Trend: ↓ losing ~${(_slopePerDay! * -7).abs().toStringAsFixed(1)} kg/week"
                          : "Trend: ↑ gaining ~${(_slopePerDay! * 7).toStringAsFixed(1)} kg/week"),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),

        // Goal predictor card (persists goal date)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Goal feasibility", style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _targetWeightC,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.flag), labelText: "Target weight (kg)"),
                      onChanged: (v) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text("Target date"),
                      subtitle: Text(DateFormat('EEE, d MMM yyyy').format(_targetDate)),
                      trailing: IconButton(
                        icon: const Icon(Icons.calendar_today),
                        onPressed: () async {
                          logging.debug("WeightsSection.pickTargetDate() open");
                          final picked = await showDatePicker(
                            context: context,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                            initialDate: _targetDate,
                          );
                          if (picked != null) {
                            logging.debug("WeightsSection.pickTargetDate() picked=$picked");
                            setState(() => _targetDate = picked);
                            await _saveGoalDate(); // NEW: persist selection
                          } else {
                            logging.debug("WeightsSection.pickTargetDate() cancelled");
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildPredictionResult(theme),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildPredictionResult(ThemeData theme) {
    final twText = _targetWeightC.text.trim();
    if (twText.isEmpty || double.tryParse(twText.replaceAll(',', '.')) == null) {
      return Text("Enter a valid target weight to evaluate feasibility.", style: theme.textTheme.bodyMedium);
    }
    final targetWeight = double.parse(twText.replaceAll(',', '.'));
    final predicted = _predictOn(_targetDate);
    if (predicted == null) {
      return Text("Not enough data to build a prediction yet.", style: theme.textTheme.bodyMedium);
    }

    final feasible = _goalFeasible(targetWeight, _targetDate);
    final ok = feasible == true;
    final color = ok ? Colors.green : Colors.red;
    final msg = ok
        ? "Likely feasible by ${DateFormat('MMM d, yyyy').format(_targetDate)}"
        : "Unlikely without stronger change by ${DateFormat('MMM d, yyyy').format(_targetDate)}";

    logging.debug("Prediction: target=$targetWeight predicted_on_date=${predicted.toStringAsFixed(1)} feasible=$feasible");

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              label: Text(ok ? "FEASIBLE" : "NOT FEASIBLE"),
              backgroundColor: color.withOpacity(0.15),
              side: BorderSide(color: color),
              labelStyle: theme.textTheme.bodyMedium?.copyWith(color: ok ? Colors.green[900] : Colors.red[900], fontWeight: FontWeight.w600),
            ),
            Text("Predicted: ${predicted.toStringAsFixed(1)} kg on ${DateFormat('MMM d').format(_targetDate)}"),
          ],
        ),
        const SizedBox(height: 6),
        Text(msg, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _Point {
  final double x;
  final double y;
  final DateTime day;
  _Point({required this.x, required this.y, required this.day});
}

class _LinRegResult {
  final double m;
  final double b;
  _LinRegResult({required this.m, required this.b});
}

class LogScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const LogScreen({super.key, required this.onSaved});
  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _weightC = TextEditingController();
  final _distC = TextEditingController();
  final _durC = TextEditingController();
  DateTime _selectedDay = DateTime.now();
  bool _busy = false;
  String? _err;

  String get _dayStr => DateFormat('yyyy-MM-dd').format(_selectedDay);

  Future<void> _saveWeight() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    logging.debug("LogScreen._saveWeight() day=$_dayStr weight_text=${_weightC.text}");
    try {
      final val = double.parse(_weightC.text.replaceAll(',', '.'));
      await ApiService.instance.weightUpsert(day: _dayStr, weightKg: val);
      widget.onSaved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Weight saved")));
        _weightC.clear();
      }
    } catch (e) {
      logging.debug("LogScreen._saveWeight() error=$e");
      setState(() {
        _err = e.toString();
      });
    } finally {
      setState(() {
        _busy = false;
      });
      logging.debug("LogScreen._saveWeight() end");
    }
  }

  Future<void> _saveRun() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    logging.debug("LogScreen._saveRun() day=$_dayStr dist_text=${_distC.text} dur_text=${_durC.text}");
    try {
      final d = double.parse(_distC.text.replaceAll(',', '.'));
      final m = double.parse(_durC.text.replaceAll(',', '.'));
      await ApiService.instance.runUpsert(day: _dayStr, distanceKm: d, durationMin: m);
      widget.onSaved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Run saved")));
        _distC.clear();
        _durC.clear();
      }
    } catch (e) {
      logging.debug("LogScreen._saveRun() error=$e");
      setState(() {
        _err = e.toString();
      });
    } finally {
      setState(() {
        _busy = false;
      });
      logging.debug("LogScreen._saveRun() end");
    }
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("LogScreen.build() selectedDay=$_selectedDay busy=$_busy");
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text("Log for ${DateFormat('EEE, d MMM yyyy').format(_selectedDay)}")),
        IconButton(
          onPressed: () async {
            logging.debug("LogScreen.pickDate() open");
            final picked = await showDatePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
              initialDate: _selectedDay,
            );
            if (picked != null) {
              logging.debug("LogScreen.pickDate() picked=$picked");
              setState(() => _selectedDay = picked);
            } else {
              logging.debug("LogScreen.pickDate() cancelled");
            }
          },
          icon: const Icon(Icons.calendar_today),
          tooltip: "Pick date",
        )
      ]),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Weigh-in", style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _weightC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.monitor_weight), labelText: "Weight (kg)"),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _saveWeight,
                icon: const Icon(Icons.save),
                label: _busy ? const Text("Saving…") : const Text("Save"),
              ),
            )
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Run", style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _distC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.directions_run), labelText: "Distance (km)"),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _durC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.timer), labelText: "Duration (min)"),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _saveRun,
                icon: const Icon(Icons.save),
                label: _busy ? const Text("Saving…") : const Text("Save"),
              ),
            )
          ]),
        ),
      ),
      if (_err != null) ...[
        const SizedBox(height: 12),
        Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]
    ]);
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _weights = [];
  List<dynamic> _runs = [];
  bool _loading = true;

  Future<void> _load() async {
    logging.debug("History._load() start");
    setState(() {
      _loading = true;
    });
    try {
      _weights = await ApiService.instance.weightsList();
      _runs = await ApiService.instance.runsList();
      logging.debug("History._load() weights=${_weights.length} runs=${_runs.length}");
    } catch (e) {
      logging.debug("History._load() error=$e");
    } finally {
      setState(() {
        _loading = false;
      });
      logging.debug("History._load() end");
    }
  }

  @override
  void initState() {
    super.initState();
    logging.debug("History.initState()");
    _load();
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("History.build() loading=$_loading");
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("Weights", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final w in _weights)
            Card(
              child: ListTile(
                leading: const Icon(Icons.monitor_weight),
                title: Text("${(w['weight_kg'] as num).toStringAsFixed(1)} kg"),
                subtitle: Text(w['day']),
              ),
            ),
          const SizedBox(height: 16),
          Text("Runs", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final r in _runs)
            Card(
              child: ListTile(
                leading: const Icon(Icons.directions_run),
                title: Text("${(r['distance_km'] as num).toStringAsFixed(1)} km • ${(r['duration_min'] as num).toStringAsFixed(0)} min"),
                subtitle: Text(r['day']),
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const SettingsScreen({super.key, required this.onSaved});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _targetC = TextEditingController();
  final _goalRunC = TextEditingController();
  TimeOfDay _weighTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _runTime = const TimeOfDay(hour: 18, minute: 0);
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    logging.debug("Settings.initState()");
    _load();
  }

  Future<void> _load() async {
    logging.debug("Settings._load() start");
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final me = await ApiService.instance.meGet();
      logging.debug("Settings._load() me=$me");
      _targetC.text = (me["target_weight"] as num).toStringAsFixed(1);
      _goalRunC.text = (me["daily_run_km"] as num).toStringAsFixed(1);
      _weighTime = _parse(me["weigh_time"]);
      _runTime = _parse(me["run_time"]);
    } catch (e) {
      logging.debug("Settings._load() error=$e");
      _err = e.toString();
    } finally {
      setState(() {
        _loading = false;
      });
      logging.debug("Settings._load() end");
    }
  }

  TimeOfDay _parse(String s) {
    final parts = s.split(":");
    final t = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    logging.debug("Settings._parse($s) -> $t");
    return t;
  }

  String _fmt(TimeOfDay t) {
    final s = "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
    logging.debug("Settings._fmt($t) -> $s");
    return s;
  }

  Future<void> _save() async {
    logging.debug("Settings._save() start");
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final me = await ApiService.instance.meUpdate(
        targetWeight: double.parse(_targetC.text.replaceAll(",", ".")),
        dailyRunKm: double.parse(_goalRunC.text.replaceAll(",", ".")),
        weighTime: _fmt(_weighTime),
        runTime: _fmt(_runTime),
      );
      logging.debug("Settings._save() me after update=$me");
      await NotificationService.instance.rescheduleBoth(me["weigh_time"], me["run_time"]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Settings saved & reminders scheduled")));
        widget.onSaved();
      }
    } catch (e) {
      logging.debug("Settings._save() error=$e");
      setState(() {
        _err = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
      logging.debug("Settings._save() end");
    }
  }

  Future<void> _pickWeigh() async {
    logging.debug("Settings._pickWeigh() open");
    final t = await showTimePicker(context: context, initialTime: _weighTime);
    if (t != null) {
      logging.debug("Settings._pickWeigh() picked=$t");
      setState(() => _weighTime = t);
    } else {
      logging.debug("Settings._pickWeigh() cancelled");
    }
  }

  Future<void> _pickRun() async {
    logging.debug("Settings._pickRun() open");
    final t = await showTimePicker(context: context, initialTime: _runTime);
    if (t != null) {
      logging.debug("Settings._pickRun() picked=$t");
      setState(() => _runTime = t);
    } else {
      logging.debug("Settings._pickRun() cancelled");
    }
  }

  @override
  Widget build(BuildContext context) {
    logging.debug("Settings.build() loading=$_loading err_present=${_err != null}");
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Goals", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _targetC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.flag), labelText: "Target weight (kg)"),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _goalRunC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.directions_run), labelText: "Daily run goal (km)"),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Daily reminders", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: ListTile(
                  leading: const Icon(Icons.monitor_weight),
                  title: const Text("Weigh-in time"),
                  subtitle: Text(_fmt(_weighTime)),
                  trailing: IconButton(onPressed: _pickWeigh, icon: const Icon(Icons.schedule)),
                )),
              ]),
              Row(children: [
                Expanded(
                    child: ListTile(
                  leading: const Icon(Icons.directions_run),
                  title: const Text("Run time"),
                  subtitle: Text(_fmt(_runTime)),
                  trailing: IconButton(onPressed: _pickRun, icon: const Icon(Icons.schedule)),
                )),
              ]),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text("Save & schedule"),
                ),
              ),
              if (_err != null) ...[
                const SizedBox(height: 8),
                Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ]
            ]),
          ),
        ),
      ],
    );
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
  bool _enabled = false;

  Future<void> init() async {
    logging.debug("NotificationService.init() start, kIsWeb=$kIsWeb");
    if (kIsWeb) {
      _enabled = false;
      logging.debug("NotificationService.init(): web -> disabled");
      return;
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _fln.initialize(initSettings);
    _enabled = true;
    await _fln
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    logging.debug("NotificationService.init(): initialized, enabled=$_enabled");
  }

  Future<void> scheduleDaily({
    required int id,
    required TimeOfDay tod,
    required String title,
    required String body,
  }) async {
    logging.debug("NotificationService.scheduleDaily(id=$id, time=${tod.hour}:${tod.minute}, title=$title)");
    if (!_enabled) {
      logging.debug("NotificationService.scheduleDaily(): not enabled, skipping");
      return;
    }
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, tod.hour, tod.minute);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    await _fln.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_channel_id',
          'Daily Reminders',
          channelDescription: 'Daily reminders for weighing and running',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
    logging.debug("NotificationService.scheduleDaily(): scheduled");
  }

  Future<void> cancel(int id) async {
    logging.debug("NotificationService.cancel(id=$id)");
    if (!_enabled) return;
    await _fln.cancel(id);
  }

  Future<void> rescheduleBoth(String weighTime, String runTime) async {
    logging.debug("NotificationService.rescheduleBoth(weighTime=$weighTime, runTime=$runTime)");
    if (!_enabled) {
      logging.debug("NotificationService.rescheduleBoth(): not enabled, skipping");
      return;
    }
    await cancel(101);
    await cancel(102);
    final wt = _parseHHmm(weighTime);
    final rt = _parseHHmm(runTime);
    await scheduleDaily(id: 101, tod: wt, title: "Weigh-in", body: "Step on the scale and log your weight.");
    await scheduleDaily(id: 102, tod: rt, title: "Run time", body: "It's your daily run. Let's go!");
  }

  TimeOfDay _parseHHmm(String s) {
    final parts = s.split(":");
    final t = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    logging.debug("NotificationService._parseHHmm($s) -> $t");
    return t;
  }
}
