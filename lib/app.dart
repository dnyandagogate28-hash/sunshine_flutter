import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/auth/profile_screen.dart';
import 'screens/auth/edit_profile_screen.dart';
import 'screens/home/create_plan_screen.dart';
import 'screens/browse/browse_plans_screen.dart';
import 'screens/plan/plan_details_screen.dart';
import 'screens/chatbot/chatbot_screen.dart';
import 'screens/auth/login_screen.dart';
import 'models/user_model.dart';

class SunshineApp extends StatelessWidget {
  const SunshineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Sunshine Holiday Packages",
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.light,
      home: const _AppInitializer(),
      onGenerateRoute: _generateRoute,
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/home': (context) => const HomeScreen(),
        '/login': (context) => const LoginScreen(),
        '/profile': (context) => const ProfileScreen(),
        '/create-plan': (context) => const CreateTravelPlanScreen(),
        '/browse': (context) => const BrowsePlansScreen(),
        '/chatbot': (context) => const ChatbotScreen(),
      },
    );
  }

  static Route<dynamic>? _generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/plan-details':
        final planId = settings.arguments as String?;
        if (planId != null) {
          return MaterialPageRoute(
            builder: (_) => PlanDetailsScreen(planId: planId),
          );
        }
        return null;
      case '/edit-profile':
        final user = settings.arguments as UserModel?;
        if (user != null) {
          return MaterialPageRoute(
            builder: (_) => EditProfileScreen(user: user),
          );
        }
        return null;
      default:
        return null;
    }
  }
}

class _AppInitializer extends StatefulWidget {
  const _AppInitializer();

  @override
  State<_AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<_AppInitializer> {
  late DateTime _startTime;
  final _minSplashDuration = const Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Calculate elapsed time
        final elapsedTime = DateTime.now().difference(_startTime);
        final shouldShowSplash = elapsedTime < _minSplashDuration;

        // Show splash screen if minimum duration hasn't passed
        if (shouldShowSplash) {
          return const SplashScreen();
        }

        // If still waiting for auth status, show splash
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }

        // If user is logged in, show home
        if (snapshot.hasData && snapshot.data != null) {
          return const HomeScreen();
        }

        // If user is not logged in, show login
        return const LoginScreen();
      },
    );
  }
}
