import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

const Color appPurple = Color(0xFF6750A4);
final NumberFormat inrFormat = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => SpendWiseState()..loadTheme(),
      child: const SpendWiseApp(),
    ),
  );
}

// -----------------------------------------------------------------------------
// APP STATE
// -----------------------------------------------------------------------------

class SpendWiseState extends ChangeNotifier {
  bool isDarkMode = false;
  bool isLoading = false;
  String? loadError;
  int selectedTab = 0;

  List<Map<String, dynamic>> transactions = [];
  List<Map<String, dynamic>> budgets = [];

  User? get currentUser => FirebaseAuth.instance.currentUser;

  CollectionReference<Map<String, dynamic>> get _transactionsRef {
    final user = currentUser;
    if (user == null) {
      throw StateError('You must be signed in to access transactions.');
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('transactions');
  }

  CollectionReference<Map<String, dynamic>> get _budgetsRef {
    final user = currentUser;
    if (user == null) {
      throw StateError('You must be signed in to access budgets.');
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('budgets');
  }

  double get totalIncome =>
      transactions.where((item) => item['type'] == 'Income').fold<double>(
            0,
            (sum, item) => sum + (item['amount'] as num).toDouble(),
          );

  double get totalExpenses =>
      transactions.where((item) => item['type'] == 'Expense').fold<double>(
            0,
            (sum, item) => sum + (item['amount'] as num).toDouble(),
          );

  double get balance => totalIncome - totalExpenses;

  Future<void> loadTheme() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      isDarkMode = preferences.getBool('spendwise_dark_mode') ?? false;
      notifyListeners();
    } catch (error) {
      debugPrint('Theme preference error: $error');
    }
  }

  Future<void> toggleTheme(bool value) async {
    isDarkMode = value;
    notifyListeners();

    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('spendwise_dark_mode', value);
    } catch (error) {
      debugPrint('Unable to save theme preference: $error');
    }
  }

  void changeTab(int index) {
    selectedTab = index;
    notifyListeners();
  }

  Future<void> loadData() async {
    if (currentUser == null) {
      transactions = [];
      budgets = [];
      isLoading = false;
      loadError = null;
      notifyListeners();
      return;
    }

    isLoading = true;
    loadError = null;
    notifyListeners();

    try {
      // Both reads run together. The timeout prevents an endless loading state.
      final snapshots = await Future.wait<QuerySnapshot<Map<String, dynamic>>>([
        _transactionsRef.orderBy('date', descending: true).get(),
        _budgetsRef.get(),
      ]).timeout(const Duration(seconds: 15));

      transactions = snapshots[0]
          .docs
          .map((document) => <String, dynamic>{
                'id': document.id,
                ...document.data(),
              })
          .toList();

      budgets = snapshots[1]
          .docs
          .map((document) => <String, dynamic>{
                'id': document.id,
                ...document.data(),
              })
          .toList();

      loadError = null;
    } on FirebaseException catch (error) {
      loadError =
          '${error.code}: ${error.message ?? 'Firebase request failed.'}';
      debugPrint('FIRESTORE ERROR: $loadError');
    } catch (error) {
      loadError = error.toString();
      debugPrint('DATA LOAD ERROR: $error');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> saveTransaction(
    Map<String, dynamic> data, {
    String? documentId,
  }) async {
    try {
      final localData = Map<String, dynamic>.from(data);

      // Firestore server timestamps are resolved by Firebase,
      // so use local timestamps for the immediate UI update.
      localData.remove('createdAt');
      localData.remove('updatedAt');

      localData['updatedAt'] = Timestamp.now();

      if (documentId == null) {
        localData['createdAt'] = Timestamp.now();

        final doc = await _transactionsRef.add(data);

        transactions.insert(0, {
          'id': doc.id,
          ...localData,
        });
      } else {
        await _transactionsRef.doc(documentId).update(data);

        final index = transactions.indexWhere(
          (item) => item['id'] == documentId,
        );

        if (index != -1) {
          transactions[index] = {
            'id': documentId,
            ...localData,
          };
        }
      }

      transactions.sort((a, b) {
        final dateA = a['date'] as Timestamp;
        final dateB = b['date'] as Timestamp;
        return dateB.compareTo(dateA);
      });

      notifyListeners();
    } catch (error) {
      debugPrint('TRANSACTION SAVE ERROR: $error');
      rethrow;
    }
  }

  Future<void> deleteTransaction(String documentId) async {
    await _transactionsRef.doc(documentId).delete();
    await loadData();
  }

  Future<void> saveBudget({
    required String category,
    required double limit,
  }) async {
    final monthKey = DateFormat('yyyy-MM').format(DateTime.now());
    final documentId = '${monthKey}_$category';

    await _budgetsRef.doc(documentId).set({
      'category': category,
      'limit': limit,
      'month': monthKey,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await loadData();
  }

  Future<void> updateDisplayName(String newName) async {
    final user = currentUser;
    if (user == null) return;

    await user.updateDisplayName(newName);
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'name': newName,
      'email': user.email,
      'currency': 'INR',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    notifyListeners();
  }
}

// -----------------------------------------------------------------------------
// APP ROOT AND AUTHENTICATION
// -----------------------------------------------------------------------------

class SpendWiseApp extends StatelessWidget {
  const SpendWiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpendWiseState>(
      builder: (context, state, child) {
        return MaterialApp(
          title: 'SpendWise',
          debugShowCheckedModeBanner: false,
          themeMode: state.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: appPurple),
            scaffoldBackgroundColor: const Color(0xFFF7F6FA),
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: appPurple,
              brightness: Brightness.dark,
            ),
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
            ),
          ),
          home: const AuthGate(),
        );
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text('Authentication error: ${snapshot.error}'),
            ),
          );
        }

        if (snapshot.data == null) {
          return const AuthScreen();
        }

        return const HomeShell();
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
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _isSignup = false;
  bool _showPassword = false;
  bool _isBusy = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isBusy = true;
      _errorMessage = '';
    });

    try {
      if (_isSignup) {
        final credential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

        await credential.user!.updateDisplayName(_nameController.text.trim());

        await FirebaseFirestore.instance
            .collection('users')
            .doc(credential.user!.uid)
            .set({
          'name': _nameController.text.trim(),
          'email': _emailController.text.trim(),
          'currency': 'INR',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = error.message ?? 'Authentication failed.';
        });
      }
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = '${error.code}: ${error.message}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _sendPasswordReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Enter a valid email address first.');
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email sent.')),
      );
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(
            () => _errorMessage = error.message ?? 'Unable to send email.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.account_balance_wallet_rounded,
                        color: appPurple,
                        size: 54,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'SpendWise',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isSignup
                            ? 'Create your account'
                            : 'Welcome back. Take control of your money.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 26),
                      if (_isSignup) ...[
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Enter your name'
                                  : null,
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: (value) => value == null ||
                                !RegExp(r'^[^@]+@[^@]+\.[^@]+$')
                                    .hasMatch(value.trim())
                            ? 'Enter a valid email'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: !_showPassword,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => _showPassword = !_showPassword,
                            ),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                          ),
                        ),
                        validator: (value) => value == null || value.length < 6
                            ? 'Password must contain at least 6 characters'
                            : null,
                      ),
                      if (_isSignup) ...[
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _confirmController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_reset),
                          ),
                          validator: (value) =>
                              value != _passwordController.text
                                  ? 'Passwords do not match'
                                  : null,
                        ),
                      ],
                      if (_errorMessage.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _isBusy ? null : _submit,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _isBusy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_isSignup ? 'Create account' : 'Login'),
                        ),
                      ),
                      TextButton(
                        onPressed: _isBusy
                            ? null
                            : () {
                                setState(() {
                                  _isSignup = !_isSignup;
                                  _errorMessage = '';
                                });
                              },
                        child: Text(
                          _isSignup
                              ? 'Already have an account? Login'
                              : 'New to SpendWise? Create account',
                        ),
                      ),
                      if (!_isSignup)
                        TextButton(
                          onPressed: _isBusy ? null : _sendPasswordReset,
                          child: const Text('Forgot password?'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// RESPONSIVE APPLICATION SHELL
// -----------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SpendWiseState>().loadData();
    });
  }

  static const List<String> _titles = [
    'Dashboard',
    'Transactions',
    'Analytics',
    'Budgets',
    'Settings',
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SpendWiseState>();
    final width = MediaQuery.sizeOf(context).width;
    final showRail = width >= 700;
    final extendedRail = width >= 1100;

    final pages = [
      const DashboardPage(),
      const TransactionsPage(),
      const AnalyticsPage(),
      const BudgetsPage(),
      const SettingsPage(),
    ];

    Widget content;
    if (state.isLoading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (state.loadError != null) {
      content = LoadErrorView(
        message: state.loadError!,
        onRetry: () => context.read<SpendWiseState>().loadData(),
      );
    } else {
      content = AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(
          key: ValueKey<int>(state.selectedTab),
          child: pages[state.selectedTab],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _titles[state.selectedTab],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            onPressed: () => state.toggleTheme(!state.isDarkMode),
            icon: Icon(
              state.isDarkMode ? Icons.light_mode : Icons.dark_mode,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          if (showRail)
            NavigationRail(
              selectedIndex: state.selectedTab,
              onDestinationSelected: state.changeTab,
              extended: extendedRail,
              labelType: extendedRail
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: Text('Dashboard'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: Text('Transactions'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.pie_chart_outline),
                  selectedIcon: Icon(Icons.pie_chart),
                  label: Text('Analytics'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.savings_outlined),
                  selectedIcon: Icon(Icons.savings),
                  label: Text('Budgets'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('Settings'),
                ),
              ],
            ),
          Expanded(child: content),
        ],
      ),
      bottomNavigationBar: showRail
          ? null
          : NavigationBar(
              selectedIndex: state.selectedTab,
              onDestinationSelected: state.changeTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.pie_chart_outline),
                  label: 'Stats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.savings_outlined),
                  label: 'Budget',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }
}

class LoadErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const LoadErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Unable to load your data',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              SelectableText(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHARED WIDGETS
// -----------------------------------------------------------------------------

class PageContainer extends StatelessWidget {
  final Widget child;

  const PageContainer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: child,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String message;

  const EmptyState({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SummaryCard extends StatelessWidget {
  final String title;
  final double amount;
  final IconData icon;
  final Color color;

  const SummaryCard({
    super.key,
    required this.title,
    required this.amount,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 255,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withOpacity(0.12),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    const SizedBox(height: 6),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: amount),
                      duration: const Duration(milliseconds: 700),
                      builder: (context, value, child) {
                        return FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: Text(
                            inrFormat.format(value),
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// DASHBOARD
// -----------------------------------------------------------------------------

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SpendWiseState>();
    final width = MediaQuery.sizeOf(context).width;

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hello, ${state.currentUser?.displayName ?? 'there'} 👋',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text('Here is your financial overview.'),
          const SizedBox(height: 22),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              SizedBox(
                width: width < 600 ? double.infinity : null,
                child: SummaryCard(
                  title: 'Total balance',
                  amount: state.balance,
                  icon: Icons.account_balance_wallet,
                  color: appPurple,
                ),
              ),
              SizedBox(
                width: width < 600 ? double.infinity : null,
                child: SummaryCard(
                  title: 'Total income',
                  amount: state.totalIncome,
                  icon: Icons.trending_up,
                  color: Colors.green,
                ),
              ),
              SizedBox(
                width: width < 600 ? double.infinity : null,
                child: SummaryCard(
                  title: 'Total expenses',
                  amount: state.totalExpenses,
                  icon: Icons.trending_down,
                  color: Colors.deepOrange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent transactions',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              FilledButton.icon(
                onPressed: () => showTransactionDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add new'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.transactions.isEmpty)
            const EmptyState(
              message: 'No transactions yet. Add your first income or expense.',
            )
          else
            ...state.transactions.take(5).map(
                  (item) => TransactionTile(data: item),
                ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// TRANSACTIONS, SEARCH AND FILTERS
// -----------------------------------------------------------------------------

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _typeFilter = 'All';
  String _categoryFilter = 'All';

  static const List<String> _categories = [
    'All',
    'Food',
    'Shopping',
    'Transport',
    'Education',
    'Entertainment',
    'Healthcare',
    'Bills',
    'Salary',
    'Freelance',
    'Other',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allTransactions = context.watch<SpendWiseState>().transactions;
    final search = _searchController.text.toLowerCase();

    final filtered = allTransactions.where((item) {
      final title = (item['title'] ?? '').toString().toLowerCase();
      final matchesSearch = title.contains(search);
      final matchesType = _typeFilter == 'All' || item['type'] == _typeFilter;
      final matchesCategory =
          _categoryFilter == 'All' || item['category'] == _categoryFilter;
      return matchesSearch && matchesType && matchesCategory;
    }).toList();

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(
                'All transactions',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              FilledButton.icon(
                onPressed: () => showTransactionDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add transaction'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 250,
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by title',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  value: _typeFilter,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: ['All', 'Income', 'Expense']
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _typeFilter = value ?? 'All'),
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  value: _categoryFilter,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: _categories
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _categoryFilter = value ?? 'All'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (filtered.isEmpty)
            const EmptyState(message: 'No matching transactions found.')
          else
            ...filtered.map(
              (item) => TransactionTile(data: item, showActions: true),
            ),
        ],
      ),
    );
  }
}

class TransactionTile extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool showActions;

  const TransactionTile({
    super.key,
    required this.data,
    this.showActions = false,
  });

  @override
  Widget build(BuildContext context) {
    final isIncome = data['type'] == 'Income';
    final rawDate = data['date'];
    final date = rawDate is Timestamp ? rawDate.toDate() : DateTime.now();
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              (isIncome ? Colors.green : Colors.deepOrange).withOpacity(0.12),
          child: Icon(
            isIncome ? Icons.arrow_downward : Icons.arrow_upward,
            color: isIncome ? Colors.green : Colors.deepOrange,
          ),
        ),
        title: Text((data['title'] ?? 'Untitled').toString()),
        subtitle: Text(
          '${data['category'] ?? 'Other'} • ${DateFormat('dd MMM yyyy').format(date)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${isIncome ? '+' : '-'}${inrFormat.format(amount)}',
              style: TextStyle(
                color: isIncome ? Colors.green : Colors.deepOrange,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (showActions)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    showTransactionDialog(context, existing: data);
                  } else if (value == 'delete') {
                    _confirmDelete(context, data['id'].toString());
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !context.mounted) return;

    try {
      await context.read<SpendWiseState>().deleteTransaction(id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $error')),
        );
      }
    }
  }
}

// -----------------------------------------------------------------------------
// ADD / EDIT TRANSACTION FORM
// -----------------------------------------------------------------------------

Future<void> showTransactionDialog(
  BuildContext context, {
  Map<String, dynamic>? existing,
}) async {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController(
    text: existing?['title']?.toString() ?? '',
  );
  final amountController = TextEditingController(
    text: existing?['amount']?.toString() ?? '',
  );
  final descriptionController = TextEditingController(
    text: existing?['description']?.toString() ?? '',
  );

  String selectedType = existing?['type']?.toString() ?? 'Expense';
  String selectedCategory = existing?['category']?.toString() ?? 'Food';
  final rawDate = existing?['date'];
  DateTime selectedDate =
      rawDate is Timestamp ? rawDate.toDate() : DateTime.now();

  const categories = [
    'Food',
    'Shopping',
    'Transport',
    'Education',
    'Entertainment',
    'Healthcare',
    'Bills',
    'Salary',
    'Freelance',
    'Other',
  ];

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: Text(
              existing == null ? 'Add transaction' : 'Edit transaction',
            ),
            content: SizedBox(
              width: 430,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: titleController,
                        decoration: const InputDecoration(
                          labelText: 'Transaction title',
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                                ? 'Enter a title'
                                : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Amount (₹)',
                        ),
                        validator: (value) {
                          final amount = double.tryParse(value ?? '');
                          if (amount == null || amount <= 0) {
                            return 'Enter an amount greater than zero';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: selectedType,
                        decoration: const InputDecoration(labelText: 'Type'),
                        items: ['Expense', 'Income']
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedType = value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: selectedCategory,
                        decoration:
                            const InputDecoration(labelText: 'Category'),
                        items: categories
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedCategory = value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description (optional)',
                        ),
                        maxLines: 2,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          DateFormat('dd MMM yyyy').format(selectedDate),
                        ),
                        trailing: const Icon(Icons.calendar_month),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() => selectedDate = picked);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;

                  try {
                    await context.read<SpendWiseState>().saveTransaction(
                      {
                        'title': titleController.text.trim(),
                        'amount': double.parse(amountController.text),
                        'type': selectedType,
                        'category': selectedCategory,
                        'description': descriptionController.text.trim(),
                        'date': Timestamp.fromDate(selectedDate),
                        'updatedAt': FieldValue.serverTimestamp(),
                        if (existing == null)
                          'createdAt': FieldValue.serverTimestamp(),
                      },
                      documentId: existing?['id']?.toString(),
                    );

                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                  } catch (error) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text('Save failed: $error')),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    titleController.dispose();
    amountController.dispose();
    descriptionController.dispose();
  });
}

// -----------------------------------------------------------------------------
// ANALYTICS
// -----------------------------------------------------------------------------

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SpendWiseState>();
    final expenseTransactions =
        state.transactions.where((item) => item['type'] == 'Expense').toList();

    final Map<String, double> categoryTotals = {};
    for (final item in expenseTransactions) {
      final category = (item['category'] ?? 'Other').toString();
      final amount = (item['amount'] as num).toDouble();
      categoryTotals[category] = (categoryTotals[category] ?? 0) + amount;
    }

    final chartColors = [
      appPurple,
      Colors.orange,
      Colors.green,
      Colors.blue,
      Colors.pink,
      Colors.teal,
      Colors.amber,
      Colors.indigo,
      Colors.redAccent,
    ];

    final maxAmount = [
      state.totalIncome,
      state.totalExpenses,
      1.0,
    ].reduce((a, b) => a > b ? a : b);

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Analytics',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Income: ${inrFormat.format(state.totalIncome)}    '
            'Expenses: ${inrFormat.format(state.totalExpenses)}',
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Expenses by category',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 14),
                  if (categoryTotals.isEmpty)
                    const EmptyState(
                      message: 'Add expenses to see your category chart.',
                    )
                  else
                    SizedBox(
                      height: 260,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: PieChart(
                              PieChartData(
                                centerSpaceRadius: 36,
                                sectionsSpace: 3,
                                sections: categoryTotals.entries
                                    .toList()
                                    .asMap()
                                    .entries
                                    .map(
                                      (entry) => PieChartSectionData(
                                        value: entry.value.value,
                                        title: '',
                                        color: chartColors[
                                            entry.key % chartColors.length],
                                        radius: 78,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 10,
                                children: categoryTotals.entries
                                    .toList()
                                    .asMap()
                                    .entries
                                    .map(
                                      (entry) => Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 11,
                                            height: 11,
                                            decoration: BoxDecoration(
                                              color: chartColors[entry.key %
                                                  chartColors.length],
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${entry.value.key}: '
                                            '${inrFormat.format(entry.value.value)}',
                                          ),
                                        ],
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Income vs expenses',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 240,
                    child: BarChart(
                      BarChartData(
                        maxY: maxAmount * 1.2,
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 48,
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (value, meta) {
                                final label =
                                    value.toInt() == 0 ? 'Income' : 'Expense';
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(label),
                                );
                              },
                            ),
                          ),
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                        ),
                        barGroups: [
                          BarChartGroupData(
                            x: 0,
                            barRods: [
                              BarChartRodData(
                                toY: state.totalIncome,
                                color: Colors.green,
                                width: 34,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ],
                          ),
                          BarChartGroupData(
                            x: 1,
                            barRods: [
                              BarChartRodData(
                                toY: state.totalExpenses,
                                color: Colors.deepOrange,
                                width: 34,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Savings rate: ${state.totalIncome <= 0 ? '0.0' : ((state.balance / state.totalIncome) * 100).toStringAsFixed(1)}%',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// MONTHLY CATEGORY BUDGETS
// -----------------------------------------------------------------------------

class BudgetsPage extends StatelessWidget {
  const BudgetsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SpendWiseState>();
    final currentMonth = DateFormat('yyyy-MM').format(DateTime.now());

    final currentBudgets = state.budgets.where(
      (budget) => budget['month'] == currentMonth,
    );

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(
                'Monthly budgets',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              FilledButton.icon(
                onPressed: () => showBudgetDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Set budget'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (currentBudgets.isEmpty)
            const EmptyState(
              message: 'No budgets set for this month. Create your first one.',
            )
          else
            ...currentBudgets.map((budget) {
              final category = budget['category'].toString();
              final limit = (budget['limit'] as num).toDouble();
              final now = DateTime.now();
              final monthStart = DateTime(now.year, now.month);
              final nextMonth = DateTime(now.year, now.month + 1);

              final spent = state.transactions.where((transaction) {
                if (transaction['type'] != 'Expense' ||
                    transaction['category'] != category) {
                  return false;
                }
                final value = transaction['date'];
                if (value is! Timestamp) return false;
                final date = value.toDate();
                return !date.isBefore(monthStart) && date.isBefore(nextMonth);
              }).fold<double>(
                0,
                (sum, transaction) =>
                    sum + (transaction['amount'] as num).toDouble(),
              );

              final progress =
                  limit <= 0 ? 0.0 : (spent / limit).clamp(0.0, 1.0);
              final status = spent >= limit
                  ? 'Budget exceeded'
                  : spent >= limit * 0.8
                      ? 'Warning: 80% or more used'
                      : '${inrFormat.format(limit - spent)} remaining';

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            category,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 17,
                            ),
                          ),
                          Text(
                            '${inrFormat.format(spent)} / ${inrFormat.format(limit)}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: progress),
                        duration: const Duration(milliseconds: 700),
                        builder: (context, value, child) {
                          return LinearProgressIndicator(
                            value: value,
                            minHeight: 10,
                            color: spent >= limit
                                ? Colors.red
                                : spent >= limit * 0.8
                                    ? Colors.orange
                                    : Colors.green,
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(status),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

Future<void> showBudgetDialog(BuildContext context) async {
  final formKey = GlobalKey<FormState>();
  final amountController = TextEditingController();
  String selectedCategory = 'Food';

  const categories = [
    'Food',
    'Shopping',
    'Transport',
    'Education',
    'Entertainment',
    'Healthcare',
    'Bills',
    'Other',
  ];

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: const Text('Set monthly category budget'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: selectedCategory,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: categories
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedCategory = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Monthly limit (₹)',
                    ),
                    validator: (value) {
                      final amount = double.tryParse(value ?? '');
                      if (amount == null || amount <= 0) {
                        return 'Enter a valid amount above zero';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;

                  try {
                    await context.read<SpendWiseState>().saveBudget(
                          category: selectedCategory,
                          limit: double.parse(amountController.text),
                        );
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                  } catch (error) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text('Budget save failed: $error')),
                      );
                    }
                  }
                },
                child: const Text('Save budget'),
              ),
            ],
          );
        },
      );
    },
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    amountController.dispose();
  });
}

// -----------------------------------------------------------------------------
// SETTINGS
// -----------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _nameController;
  bool _isSavingName = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: FirebaseAuth.instance.currentUser?.displayName ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty.')),
      );
      return;
    }

    setState(() => _isSavingName = true);
    try {
      await context.read<SpendWiseState>().updateDisplayName(name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Display name updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Name update failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSavingName = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SpendWiseState>();
    final user = state.currentUser;

    return PageContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settings',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Profile',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      child: Icon(Icons.person),
                    ),
                    title: Text(user?.email ?? 'Signed-in user'),
                    subtitle: const Text('Firebase authenticated account'),
                  ),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _isSavingName ? null : _saveName,
                    child: _isSavingName
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save name'),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: SwitchListTile(
              title: const Text('Dark mode'),
              subtitle: const Text('Change application appearance'),
              value: state.isDarkMode,
              onChanged: state.toggleTheme,
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.currency_rupee),
              title: Text('Currency'),
              subtitle: Text('Indian Rupee (INR)'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}
