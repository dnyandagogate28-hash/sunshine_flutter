import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/travel_plan_model.dart';
import '../../models/review_model.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common_widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../../config/env_config.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'dart:convert';

class PlanDetailsScreen extends StatefulWidget {
  final String planId;

  const PlanDetailsScreen({super.key, required this.planId});

  @override
  State<PlanDetailsScreen> createState() => _PlanDetailsScreenState();
}

class _PlanDetailsScreenState extends State<PlanDetailsScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  late GoogleMapController _mapController;
  final TextEditingController _reviewController = TextEditingController();
  double _userRating = 0;
  List<LatLng> _routePolylinePoints = [];
  late Future<TravelPlan?> _planFuture;
  String? _monumentImageUrl;
  bool _isFetchingMonument = false;

  @override
  void initState() {
    super.initState();
    // Cache the future to prevent rebuilds from creating new futures
    _planFuture = _firestoreService.getTravelPlanById(widget.planId);

    // Pre-fetch the route so it's ready when map loads
    _planFuture.then((plan) async {
      if (plan != null && mounted && !_isFetchingMonument) {
        _isFetchingMonument = true;

        final image = await _fetchBestMonumentImage(plan.destination);

        if (mounted && image != null) {
          setState(() {
            _monumentImageUrl = image;
          });
        }

        _isFetchingMonument = false;
      }
    });
  }

  void _fitMapToRoute(List<LatLngPoint> routePoints) {
    if (routePoints.isEmpty || !mounted) {
      print('Cannot fit map to route: empty points or not mounted');
      return;
    }

    try {
      double minLat = routePoints[0].latitude;
      double maxLat = routePoints[0].latitude;
      double minLng = routePoints[0].longitude;
      double maxLng = routePoints[0].longitude;

      for (var point in routePoints) {
        if (point.latitude.isNaN || point.longitude.isNaN) continue;

        minLat = minLat > point.latitude ? point.latitude : minLat;
        maxLat = maxLat < point.latitude ? point.latitude : maxLat;
        minLng = minLng > point.longitude ? point.longitude : minLng;
        maxLng = maxLng < point.longitude ? point.longitude : maxLng;
      }

      // Add padding to bounds
      final padding = 0.05;
      final boundsWithPadding = LatLngBounds(
        southwest: LatLng(minLat - padding, minLng - padding),
        northeast: LatLng(maxLat + padding, maxLng + padding),
      );

      _mapController.animateCamera(
        CameraUpdate.newLatLngBounds(boundsWithPadding, 100.0),
      );

      print('Map fit to route with ${routePoints.length} points');
    } catch (e) {
      print('Error fitting map to route: $e');
    }
  }

  /// Fetch actual road directions from Google Directions API
  Future<void> _getActualRouteDirections(TravelPlan plan) async {
    if (plan.routePoints.isEmpty || plan.routePoints.length < 2) {
      print('❌ Not enough route points for directions');
      return;
    }

    if (!mounted) return;

    final stopwatch = Stopwatch()..start();

    try {
      final apiKey = EnvConfig.googleMapsApiKey;

      print('\n' + ('=' * 60));
      print('🗺️  GOOGLE DIRECTIONS API REQUEST');
      print('=' * 60);
      print('API Key provided: ${apiKey.isNotEmpty}');
      print(
        'API Key (masked): ${apiKey.isNotEmpty ? apiKey.substring(0, 10) + '...' + apiKey.substring(apiKey.length - 5) : 'NOT PROVIDED'}',
      );

      if (apiKey.isEmpty) {
        print('❌ CRITICAL: Google Maps API key is EMPTY!');
        print('   ⚙️ The Google Maps Static API may not be enabled');
        print(
          '   ⚙️ Check: Google Cloud Console → APIs → Static Maps API → Enable',
        );
        _useDefaultRoute();
        return;
      }

      // Get start and end points
      final start = plan.routePoints.first;
      final end = plan.routePoints.last;

      print('📍 Start: (${start.latitude}, ${start.longitude})');
      print('📍 End: (${end.latitude}, ${end.longitude})');
      print('📌 Total waypoints: ${plan.routePoints.length}');

      // Build waypoints from intermediate points
      String waypoints = '';
      if (plan.routePoints.length > 2) {
        final intermediatePoints = plan.routePoints.sublist(
          1,
          plan.routePoints.length - 1,
        );
        final waypointsToUse = intermediatePoints.take(25).toList();
        if (waypointsToUse.isNotEmpty) {
          waypoints =
              '&waypoints=' +
              waypointsToUse
                  .map((p) => '${p.latitude},${p.longitude}')
                  .join('|');
          print('   └─ Using ${waypointsToUse.length} intermediate waypoints');
        }
      }

      final url =
          'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${start.latitude},${start.longitude}'
          '&destination=${end.latitude},${end.longitude}'
          '$waypoints'
          '&mode=driving'
          '&key=$apiKey';

      print('\n🔗 Sending request to Google Directions API...');
      final apiCallStart = Stopwatch()..start();

      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              stopwatch.stop();
              apiCallStart.stop();
              print('⏰ TIMEOUT after ${apiCallStart.elapsedMilliseconds}ms');
              print('   ⚠️ Google Directions API took too long to respond');
              print('   ⚙️ Check internet connection or API quota');
              throw Exception('Request timeout');
            },
          );

      apiCallStart.stop();
      print('✓ Response received in ${apiCallStart.elapsedMilliseconds}ms');
      print('📡 HTTP Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        print('📥 Response body length: ${response.body.length} bytes');

        try {
          final json = jsonDecode(response.body);
          final status = json['status'] ?? 'UNKNOWN';

          print('API Response Status: $status');

          if (json['error_message'] != null) {
            print('⚠️  API Error: ${json['error_message']}');
          }

          if (status == 'OK' && (json['routes'] as List).isNotEmpty) {
            final route = json['routes'][0];

            if (route['overview_polyline'] != null) {
              final overviewPolyline = route['overview_polyline'];
              if (overviewPolyline['points'] != null) {
                final polylinePoints = overviewPolyline['points'] as String;

                print('\n📊 Polyline decoding...');
                print('   Encoded length: ${polylinePoints.length} chars');

                final decodeResult = PolylinePoints().decodePolyline(
                  polylinePoints,
                );

                final polylinePointsDecoded = decodeResult
                    .map((point) => LatLng(point.latitude, point.longitude))
                    .toList();

                stopwatch.stop();
                final totalMs = stopwatch.elapsedMilliseconds;

                print(
                  '✅ SUCCESS: Decoded ${polylinePointsDecoded.length} road coordinates',
                );
                print(
                  '⏱️  Total time: ${totalMs}ms (${(totalMs / 1000).toStringAsFixed(2)}s)',
                );
                print('=' * 60 + '\n');

                if (mounted && polylinePointsDecoded.isNotEmpty) {
                  setState(() {
                    _routePolylinePoints = polylinePointsDecoded;
                  });
                  print('🎯 Route displayed on map!\n');
                }
              } else {
                stopwatch.stop();
                print('❌ No polyline points in response');
                print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
                _useDefaultRoute();
              }
            } else {
              stopwatch.stop();
              print('❌ No overview_polyline in route');
              print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
              _useDefaultRoute();
            }
          } else {
            stopwatch.stop();
            print('❌ API returned non-OK status: $status');
            if (status == 'REQUEST_DENIED') {
              print('   ⚙️ Check: API Key enabled in Google Cloud Console');
              print('   ⚙️ Check: Maps Directions API is enabled');
              print(
                '   ⚙️ Check: API Key has correct restrictions/permissions',
              );
            }
            print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
            _useDefaultRoute();
          }
        } catch (parseError) {
          stopwatch.stop();
          print('❌ JSON parse error: $parseError');
          print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
          _useDefaultRoute();
        }
      } else {
        stopwatch.stop();
        print('❌ HTTP Error: ${response.statusCode}');
        print('   Response: ${response.body.substring(0, 200)}...');
        print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
        _useDefaultRoute();
      }
    } catch (e) {
      stopwatch.stop();
      print('❌ Exception: $e');
      print('⏱️  Failed after ${stopwatch.elapsedMilliseconds}ms');
      print('=' * 60 + '\n');
      _useDefaultRoute();
    }
  }

  /// Fallback to default route using waypoints
  void _useDefaultRoute() {
    if (mounted) {
      setState(() {
        // Use original route points as fallback
        _routePolylinePoints = [];
      });
      print('Using default route (direct waypoints)');
    }
  }

  Future<String?> _fetchBestMonumentImage(String destination) async {
    try {
      final apiKey = EnvConfig.googleMapsApiKey;

      if (apiKey.isEmpty) {
        print("Places API key missing");
        return null;
      }

      final searchUrl =
          "https://maps.googleapis.com/maps/api/place/textsearch/json"
          "?query=${Uri.encodeComponent(destination + " famous monument")}"
          "&type=tourist_attraction"
          "&key=$apiKey";

      final response = await http.get(Uri.parse(searchUrl));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);

        if (json["results"] != null && json["results"].isNotEmpty) {
          final firstPlace = json["results"][0];

          if (firstPlace["photos"] != null && firstPlace["photos"].isNotEmpty) {
            final photoReference = firstPlace["photos"][0]["photo_reference"];

            return "https://maps.googleapis.com/maps/api/place/photo"
                "?maxwidth=1200"
                "&photo_reference=$photoReference"
                "&key=$apiKey";
          }
        }
      }
    } catch (e) {
      print("Monument fetch error: $e");
    }

    return null;
  }

  void _submitReview(TravelPlan plan) async {
    if (_userRating == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a rating')));
      return;
    }

    if (_reviewController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please write a review')));
      return;
    }

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please login to add a review')),
        );
        return;
      }

      final review = ReviewModel(
        reviewId: const Uuid().v4(),
        planId: widget.planId,
        userId: user.uid,
        userName: user.displayName ?? 'Anonymous',
        rating: _userRating,
        comment: _reviewController.text,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _firestoreService.addReview(review);

      _reviewController.clear();
      setState(() => _userRating = 0);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Review added successfully!'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _savePlan(TravelPlan plan) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please login to save plans')),
        );
        return;
      }

      await _firestoreService.savePlanToUser(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Plan saved successfully!'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error saving plan: $e')));
    }
  }

  Future<void> _generateAndDownloadPDF(TravelPlan plan) async {
    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Generating PDF...')));

      final pdf = pw.Document();

      // Add pages to PDF
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20),
          build: (pw.Context context) {
            return [
              // Header with Destination
              pw.Header(
                level: 0,
                child: pw.Container(
                  padding: const pw.EdgeInsets.only(bottom: 20),
                  decoration: pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(
                        width: 2,
                        color: PdfColor.fromInt(0xFFFF9800),
                      ),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        plan.destination,
                        style: pw.TextStyle(
                          fontSize: 32,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromInt(0xFFFF9800),
                        ),
                      ),
                      pw.SizedBox(height: 8),
                      pw.Text(
                        'Travel Plan by ${plan.userName}',
                        style: const pw.TextStyle(
                          fontSize: 12,
                          color: PdfColors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(height: 20),

              // Key Details Section
              pw.Text(
                'Key Details',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromInt(0xFFFF9800),
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Table.fromTextArray(
                context: context,
                data: [
                  ['Destination', 'Duration', 'Budget', 'Starting Point'],
                  [
                    plan.destination,
                    '${plan.duration} Days',
                    '₹${plan.budget.toStringAsFixed(0)}',
                    plan.startLocation,
                  ],
                ],
                cellStyle: const pw.TextStyle(fontSize: 11),
                headerStyle: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
                headerDecoration: pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFFFF9800),
                ),
                cellPadding: const pw.EdgeInsets.all(8),
              ),
              pw.SizedBox(height: 20),

              // Day-wise Plans
              if (plan.dayWisePlans.isNotEmpty) ...[
                pw.Text(
                  'Day-wise Plans',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFFFF9800),
                  ),
                ),
                pw.SizedBox(height: 10),
                ...plan.dayWisePlans.asMap().entries.map((entry) {
                  return pw.Container(
                    margin: const pw.EdgeInsets.only(bottom: 12),
                    padding: const pw.EdgeInsets.all(10),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(
                        color: PdfColor.fromInt(0xFFFF9800),
                        width: 1,
                      ),
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(8),
                      ),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Day ${entry.key + 1}',
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromInt(0xFFFF9800),
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        ..._getBulletPoints(entry.value)
                            .map(
                              (point) => pw.Padding(
                                padding: const pw.EdgeInsets.only(bottom: 4),
                                child: pw.Row(
                                  crossAxisAlignment:
                                      pw.CrossAxisAlignment.start,
                                  children: [
                                    pw.Text(
                                      '• ',
                                      style: const pw.TextStyle(fontSize: 10),
                                    ),
                                    pw.Expanded(
                                      child: pw.Text(
                                        point,
                                        style: const pw.TextStyle(fontSize: 10),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ],
                    ),
                  );
                }).toList(),
                pw.SizedBox(height: 20),
              ],

              // Places to Visit
              if (plan.placesList.isNotEmpty) ...[
                pw.Text(
                  'Places to Visit',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFFFF9800),
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromInt(0xFFFF9800),
                      width: 1,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(8),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: _getBulletPoints(plan.placesList)
                        .map(
                          (point) => pw.Padding(
                            padding: const pw.EdgeInsets.only(bottom: 6),
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                                pw.Text(
                                  '• ',
                                  style: const pw.TextStyle(fontSize: 10),
                                ),
                                pw.Expanded(
                                  child: pw.Text(
                                    point,
                                    style: const pw.TextStyle(fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                pw.SizedBox(height: 20),
              ],

              // Budget
              if (plan.dayWiseBudget.isNotEmpty) ...[
                pw.Text(
                  'Budget Breakdown',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFFFF9800),
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromInt(0xFFFF9800),
                      width: 1,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(8),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: _getBulletPoints(plan.dayWiseBudget)
                        .map(
                          (point) => pw.Padding(
                            padding: const pw.EdgeInsets.only(bottom: 6),
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                                pw.Text(
                                  '• ',
                                  style: const pw.TextStyle(fontSize: 10),
                                ),
                                pw.Expanded(
                                  child: pw.Text(
                                    point,
                                    style: const pw.TextStyle(fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                pw.SizedBox(height: 20),
              ],

              // Transportation
              if (plan.transportation.isNotEmpty) ...[
                pw.Text(
                  'Transportation Options',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFFFF9800),
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromInt(0xFFFF9800),
                      width: 1,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(8),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: _getBulletPoints(plan.transportation)
                        .map(
                          (point) => pw.Padding(
                            padding: const pw.EdgeInsets.only(bottom: 6),
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                                pw.Text(
                                  '• ',
                                  style: const pw.TextStyle(fontSize: 10),
                                ),
                                pw.Expanded(
                                  child: pw.Text(
                                    point,
                                    style: const pw.TextStyle(fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                pw.SizedBox(height: 20),
              ],

              // Hotels & Restaurants
              if (plan.hotelsRestaurants.isNotEmpty) ...[
                pw.Text(
                  'Hotels & Restaurants',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFFFF9800),
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromInt(0xFFFF9800),
                      width: 1,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(8),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: _getBulletPoints(plan.hotelsRestaurants)
                        .map(
                          (point) => pw.Padding(
                            padding: const pw.EdgeInsets.only(bottom: 6),
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                                pw.Text(
                                  '• ',
                                  style: const pw.TextStyle(fontSize: 10),
                                ),
                                pw.Expanded(
                                  child: pw.Text(
                                    point,
                                    style: const pw.TextStyle(fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],

              // Footer
              pw.SizedBox(height: 20),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Text(
                'Generated on ${DateTime.now().toString().split('.')[0]}',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey),
              ),
            ];
          },
        ),
      );

      // Get app cache directory (no permissions needed)
      final appCacheDir = await getApplicationCacheDirectory();
      print('App Cache Directory: ${appCacheDir.path}');

      // Create Travel Plans subfolder
      final travelPlansDir = Directory('${appCacheDir.path}/TravelPlans');
      print('Travel Plans Directory: ${travelPlansDir.path}');

      if (!await travelPlansDir.exists()) {
        print('Creating TravelPlans folder...');
        await travelPlansDir.create(recursive: true);
        print('TravelPlans folder created successfully');
      } else {
        print('TravelPlans folder already exists');
      }

      // Save PDF
      final fileName =
          'travel_plan_${plan.destination.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final filePath = '${travelPlansDir.path}/$fileName';
      final file = File(filePath);

      print('Saving PDF to: $filePath');
      final pdfBytes = await pdf.save();
      await file.writeAsBytes(pdfBytes);

      print('PDF saved successfully');
      print('File size: ${file.lengthSync()} bytes');
      print('File exists: ${await file.exists()}');

      if (!mounted) return;

      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '✓ PDF Downloaded!',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fileName,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  print('Opening PDF: $filePath');
                  await launchUrl(Uri.file(filePath));
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.success,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      print('PDF Generation Error: $e');
      print('Error type: ${e.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '❌ Download Error',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                'Error: $e',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  List<String> _getBulletPoints(String content) {
    final bulletPoints = <String>[];
    final lines = content.split('\n');

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      String cleanedLine = trimmed
          .replaceAll(RegExp(r'^[\u2022\-\u2713*]+\s*'), '')
          .replaceAll(RegExp(r'^\d+\.\s*'), '')
          .trim();

      cleanedLine = cleanedLine.replaceAll('**', '').replaceAll('*', '');

      if (cleanedLine.isNotEmpty) {
        bulletPoints.add(cleanedLine);
      }
    }

    return bulletPoints.isEmpty ? [content] : bulletPoints;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan Details'),
        elevation: 0,
        actions: [
          FutureBuilder<TravelPlan?>(
            future: _planFuture,
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data != null) {
                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: () => _generateAndDownloadPDF(snapshot.data!),
                      tooltip: 'Download as PDF',
                    ),
                    IconButton(
                      icon: const Icon(Icons.bookmark_outline),
                      onPressed: () => _savePlan(snapshot.data!),
                      tooltip: 'Save this plan',
                    ),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: FutureBuilder<TravelPlan?>(
        future: _planFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingWidget(message: 'Loading plan...');
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                    color: AppColors.error,
                  ),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => setState(() {}),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final plan = snapshot.data;
          if (plan == null) {
            return const EmptyStateWidget(
              title: 'Plan Not Found',
              message: 'The travel plan could not be loaded',
              icon: Icons.map_outlined,
            );
          }

          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Destination Image Section
                _buildDestinationImageSection(context, plan),

                // 2. Highlights Section (Destination, Budget, Duration)
                _buildHighlightsSection(context, plan),

                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(color: AppColors.lightGrey),
                ),
                const SizedBox(height: 16),

                // 3. Route Map Section
                _buildRouteMapSection(context, plan),

                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(color: AppColors.lightGrey),
                ),
                const SizedBox(height: 16),

                // 4. Travel Plan Description Section
                _buildDescriptionSection(context, plan),

                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(color: AppColors.lightGrey),
                ),
                const SizedBox(height: 16),

                // 5. User Reviews Marquee Section
                _buildReviewsMarqueeSection(context),

                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(color: AppColors.lightGrey),
                ),
                const SizedBox(height: 16),

                // 6. Add Review Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildAddReviewSection(plan),
                ),

                const SizedBox(height: 30),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddReviewSection(TravelPlan plan) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Share Your Experience',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            RatingWidget(
              rating: _userRating,
              onRatingUpdate: (rating) => setState(() => _userRating = rating),
              readOnly: false,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _reviewController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Share your experience with this travel plan...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: CustomButton(
                text: 'Submit Review',
                onPressed: () => _submitReview(plan),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(String marker, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            marker,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  List<Widget> _getCategoryLegends() {
    final categories = {
      'temple': Color.fromARGB(255, 255, 152, 0),
      'beach': Color.fromARGB(255, 0, 188, 212),
      'restaurant': Color.fromARGB(255, 255, 235, 59),
      'museum': Color.fromARGB(255, 156, 39, 176),
      'market': Color.fromARGB(255, 0, 150, 136),
      'natural': Colors.green,
    };

    return categories.entries.map((entry) {
      return _buildLegendItem(
        '●',
        entry.key[0].toUpperCase() + entry.key.substring(1),
        entry.value,
      );
    }).toList();
  }

  // NEW BUILDER METHODS FOR RESTRUCTURED LAYOUT

  /// 1. Builds the destination image section at the top
  Widget _buildDestinationImageSection(BuildContext context, TravelPlan plan) {
    return Container(
      width: double.infinity,
      height: 300,
      decoration: BoxDecoration(color: AppColors.veryLightGrey),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Destination Image - Using the best monument or destination image
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: _monumentImageUrl != null && _monumentImageUrl!.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: _monumentImageUrl!,
                    fit: BoxFit.cover,
                    cacheKey: 'destination_${plan.id}',
                    memCacheHeight: 600,
                    memCacheWidth: 800,
                    progressIndicatorBuilder: (context, url, downloadProgress) {
                      return Container(
                        color: AppColors.veryLightGrey,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: downloadProgress.progress,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Loading ${plan.destination} landmark...',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    errorWidget: (context, url, error) {
                      print('\n❌ LANDMARK IMAGE LOAD FAILED');
                      print('   Destination: ${plan.destination}');
                      print('   URL: $url');
                      print('   Error type: ${error.runtimeType}');
                      print('   Error: $error');

                      // Return a beautiful gradient as fallback with destination name
                      return Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppColors.darkOrange.withOpacity(0.8),
                              AppColors.darkOrange.withOpacity(0.5),
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.landscape,
                              size: 100,
                              color: Colors.white.withOpacity(0.7),
                            ),
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    plan.destination,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Your Travel Destination',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Colors.white.withOpacity(0.8),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : Container(
                    color: AppColors.veryLightGrey,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.landscape,
                            size: 100,
                            color: Colors.grey.withOpacity(0.7),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            plan.destination,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          // Gradient overlay
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.4)],
                ),
              ),
            ),
          ),
          // Destination title overlay
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.destination,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Created by ${plan.userName}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 2. Builds the highlights section with Destination, Budget, and Duration
  Widget _buildHighlightsSection(BuildContext context, TravelPlan plan) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rating section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Highlights',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Key details of your travel plan',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.grey),
                  ),
                ],
              ),
              Column(
                children: [
                  RatingWidget(
                    rating: plan.averageRating,
                    readOnly: true,
                    itemSize: 20,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${plan.reviewCount} reviews',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Highlights Cards
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildHighlightCard(
                Icons.location_on_outlined,
                'Destination',
                plan.destination,
              ),
              _buildHighlightCard(
                Icons.calendar_today,
                'Duration',
                '${plan.duration} Days',
              ),
              _buildHighlightCard(
                Icons.currency_rupee,
                'Budget',
                '₹${plan.budget.toStringAsFixed(0)}',
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Start location info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.veryLightGrey,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.place_outlined,
                  color: AppColors.darkOrange,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Starting Point',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: AppColors.grey),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        plan.startLocation,
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 3. Builds the route map section
  Widget _buildRouteMapSection(BuildContext context, TravelPlan plan) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Route Map', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          // Route status indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _routePolylinePoints.isNotEmpty
                  ? const Color(0xFFE8F5E9) // Light green for actual route
                  : const Color(0xFFFFF3E0), // Light orange for waypoints
              border: Border.all(
                color: _routePolylinePoints.isNotEmpty
                    ? const Color(0xFF4CAF50) // Green for actual route
                    : AppColors.darkOrange,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  _routePolylinePoints.isNotEmpty
                      ? Icons.check_circle
                      : Icons.schedule,
                  size: 20,
                  color: _routePolylinePoints.isNotEmpty
                      ? const Color(0xFF4CAF50)
                      : AppColors.darkOrange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _routePolylinePoints.isNotEmpty
                            ? '✓ Real Road Routes Loaded'
                            : '⟳ Loading Routes...',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _routePolylinePoints.isNotEmpty
                              ? const Color(0xFF2E7D32)
                              : AppColors.darkOrange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _routePolylinePoints.isNotEmpty
                            ? 'Actual roads from Google Maps (not straight lines)'
                            : 'If stuck: Check API keys are enabled in Google Cloud Console',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _routePolylinePoints.isNotEmpty
                              ? const Color(0xFF2E7D32).withOpacity(0.7)
                              : AppColors.darkOrange.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (plan.routePoints.isNotEmpty)
            Card(
              child: Column(
                children: [
                  SizedBox(
                    height: 400,
                    child: GoogleMap(
                      gestureRecognizers:
                          <Factory<OneSequenceGestureRecognizer>>{
                            Factory<OneSequenceGestureRecognizer>(
                              () => EagerGestureRecognizer(),
                            ),
                          },
                      key: ValueKey(
                        'detailed_map_${widget.planId}_${_routePolylinePoints.length}',
                      ),
                      initialCameraPosition: CameraPosition(
                        target: LatLng(
                          plan.routePoints.first.latitude.isNaN
                              ? 20.5937
                              : plan.routePoints.first.latitude,
                          plan.routePoints.first.longitude.isNaN
                              ? 78.9629
                              : plan.routePoints.first.longitude,
                        ),
                        zoom: 8,
                      ),
                      myLocationEnabled: false,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      compassEnabled: true,
                      mapToolbarEnabled: true,
                      scrollGesturesEnabled: true,
                      zoomGesturesEnabled: true,
                      rotateGesturesEnabled: true,
                      tiltGesturesEnabled: true,
                      cameraTargetBounds: CameraTargetBounds.unbounded,
                      minMaxZoomPreference: const MinMaxZoomPreference(5, 20),
                      onMapCreated: (controller) {
                        if (mounted && plan.routePoints.isNotEmpty) {
                          _mapController = controller;
                          // Fetch actual route directions
                          _getActualRouteDirections(plan);
                          Future.delayed(const Duration(milliseconds: 800), () {
                            if (mounted) {
                              _fitMapToRoute(plan.routePoints);
                            }
                          });
                        }
                      },
                      polylines: {
                        // ONLY show actual road-based routes from Google Directions API
                        // NO straight lines - only real roads!
                        if (_routePolylinePoints.isNotEmpty) ...[
                          // Shadow/outline (white background for road visibility)
                          Polyline(
                            polylineId: const PolylineId('route_shadow'),
                            points: _routePolylinePoints,
                            color: Colors.white,
                            width: 18,
                            geodesic: true,
                            zIndex: 1,
                          ),
                          // Main route highlight - ACTUAL ROADS ONLY
                          Polyline(
                            polylineId: const PolylineId('route_road'),
                            points: _routePolylinePoints,
                            color: const Color(
                              0xFFFF6F00,
                            ), // Deep orange for strong visibility
                            width: 14,
                            geodesic: true,
                            zIndex: 2,
                          ),
                          // Inner highlight for better contrast
                          Polyline(
                            polylineId: const PolylineId('route_highlight'),
                            points: _routePolylinePoints,
                            color: const Color(
                              0xFFFFB74D,
                            ), // Light orange inner path
                            width: 8,
                            geodesic: true,
                            zIndex: 3,
                          ),
                        ],
                      },
                      markers: {
                        if (plan.routePoints.isNotEmpty)
                          Marker(
                            markerId: const MarkerId('start_detailed'),
                            position: LatLng(
                              plan.routePoints[0].latitude,
                              plan.routePoints[0].longitude,
                            ),
                            infoWindow: InfoWindow(
                              title: 'Starting Point',
                              snippet: plan.startLocation,
                            ),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueGreen,
                            ),
                          ),
                        if (plan.routePoints.isNotEmpty)
                          Marker(
                            markerId: const MarkerId('end_detailed'),
                            position: LatLng(
                              plan.routePoints.last.latitude,
                              plan.routePoints.last.longitude,
                            ),
                            infoWindow: InfoWindow(
                              title: 'Destination',
                              snippet: plan.destination,
                            ),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueRed,
                            ),
                          ),
                        // Popular places markers
                        ...plan.popularPlaces
                            .asMap()
                            .entries
                            .where((entry) {
                              final place = entry.value;
                              return !place.latitude.isNaN &&
                                  !place.longitude.isNaN &&
                                  place.latitude != 0 &&
                                  place.longitude != 0;
                            })
                            .map((entry) {
                              final index = entry.key;
                              final place = entry.value;

                              double hue;
                              switch (place.category.toLowerCase()) {
                                case 'temple':
                                  hue = BitmapDescriptor.hueOrange;
                                  break;
                                case 'beach':
                                  hue = BitmapDescriptor.hueCyan;
                                  break;
                                case 'restaurant':
                                  hue = BitmapDescriptor.hueYellow;
                                  break;
                                case 'museum':
                                  hue = BitmapDescriptor.hueViolet;
                                  break;
                                case 'market':
                                  hue = BitmapDescriptor.hueAzure;
                                  break;
                                case 'natural':
                                  hue = BitmapDescriptor.hueGreen;
                                  break;
                                default:
                                  hue = BitmapDescriptor.hueBlue;
                              }

                              return Marker(
                                markerId: MarkerId('place_$index'),
                                position: LatLng(
                                  place.latitude,
                                  place.longitude,
                                ),
                                infoWindow: InfoWindow(
                                  title: place.name,
                                  snippet: place.description,
                                ),
                                icon: BitmapDescriptor.defaultMarkerWithHue(
                                  hue,
                                ),
                              );
                            })
                            .toSet(),
                      },
                      onTap: (LatLng latLng) {
                        // Allows smooth dragging with single finger
                        // Only pinch gestures trigger zoom
                      },
                    ),
                  ),
                  // Map footer with legend
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (plan.popularPlaces.isNotEmpty)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '📍 Places to Visit',
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  _buildLegendItem('●', 'Start', Colors.green),
                                  _buildLegendItem(
                                    '●',
                                    'Destination',
                                    Colors.red,
                                  ),
                                  ..._getCategoryLegends(),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.veryLightGrey,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.lightGrey),
              ),
              child: Column(
                children: [
                  Icon(Icons.map_outlined, size: 48, color: AppColors.grey),
                  const SizedBox(height: 12),
                  Text(
                    'Map data not available',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Parse description into categorized sections
  /// [Deprecated] - Kept for future implementation
  // ignore: unused_element
  Map<String, String> _parseCategorizedSections(String description) {
    final sections = <String, String>{
      'overview': '',
      'accommodation_dining': '',
      'budget': '',
      'attractions': '',
      'travel_tips': '',
      'safety_practical': '',
      'travel_options': '',
      'day_wise': '',
    };

    // Define keywords for each section
    // ignore: unused_local_variable
    const overviewKeywords = [
      'overview',
      'introduction',
      'about the trip',
      'trip summary',
    ];
    // ignore: unused_local_variable
    const accommodationKeywords = [
      'accommodation',
      'lodging',
      'hotel',
      'dining',
      'restaurant',
      'food',
      'meals',
      'stay',
    ];
    // ignore: unused_local_variable
    const budgetKeywords = [
      'budget',
      'cost',
      'price',
      'expense',
      'expenditure',
    ];
    // ignore: unused_local_variable
    const attractionsKeywords = [
      'attraction',
      'places',
      'sights',
      'landmark',
      'monument',
      'visit',
    ];
    // ignore: unused_local_variable
    const travelTipsKeywords = [
      'tip',
      'advice',
      'recommendation',
      'suggestion',
      'travel tip',
    ];
    // ignore: unused_local_variable
    const safetyKeywords = [
      'safety',
      'precaution',
      'guideline',
      'health',
      'practical',
      'information',
    ];
    // ignore: unused_local_variable
    const travelOptionsKeywords = [
      'travel option',
      'transport',
      'flight',
      'train',
      'bus',
      'departure',
      'arrival',
      'mode of transport',
    ];
    // ignore: unused_local_variable
    const dayKeywords = ['day', 'hour'];

    final lines = description.split('\n');
    String currentSection = 'overview';
    final sectionContent = <String, List<String>>{};

    // Initialize sections
    for (final section in sections.keys) {
      sectionContent[section] = [];
    }

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      final lowerLine = line.toLowerCase();

      // Detect section headers
      if (lowerLine.contains('overview') ||
          lowerLine.contains('introduction') ||
          lowerLine.contains('about the trip')) {
        currentSection = 'overview';
        continue;
      } else if (lowerLine.contains('accommodation') ||
          lowerLine.contains('dining') ||
          lowerLine.contains('restaurant') ||
          lowerLine.contains('food') ||
          lowerLine.contains('lodging')) {
        currentSection = 'accommodation_dining';
        continue;
      } else if (lowerLine.contains('budget') || lowerLine.contains('cost')) {
        currentSection = 'budget';
        continue;
      } else if (lowerLine.contains('attraction') ||
          lowerLine.contains('places') ||
          lowerLine.contains('landmark')) {
        currentSection = 'attractions';
        continue;
      } else if (lowerLine.contains('tip') || lowerLine.contains('advice')) {
        currentSection = 'travel_tips';
        continue;
      } else if (lowerLine.contains('safety') ||
          lowerLine.contains('practical') ||
          lowerLine.contains('health')) {
        currentSection = 'safety_practical';
        continue;
      } else if (lowerLine.contains('travel option') ||
          lowerLine.contains('transport') ||
          lowerLine.contains('flight') ||
          lowerLine.contains('train') ||
          lowerLine.contains('bus') ||
          lowerLine.contains('departure') ||
          lowerLine.contains('arrival') ||
          lowerLine.contains('mode of transport')) {
        currentSection = 'travel_options';
        continue;
      } else if (RegExp(
        r'^\s*(Day|Hour)\s*\d+',
        multiLine: true,
      ).hasMatch(line)) {
        currentSection = 'day_wise';
      }

      sectionContent[currentSection]?.add(line);
    }

    // Combine lines for each section
    for (final key in sectionContent.keys) {
      if (sectionContent[key]!.isNotEmpty) {
        sections[key] = sectionContent[key]!.join('\n').trim();
      }
    }

    // If no explicit sections found, treat all as overview
    if (sections.values.every((v) => v.isEmpty)) {
      sections['overview'] = description;
    }

    return sections;
  }

  /// Extract bullet points from content
  List<String> _parseToBulletPoints(String content) {
    final bulletPoints = <String>[];

    // Split by newlines
    final lines = content.split('\n');

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Remove existing bullet characters if any
      String cleanedLine = trimmed
          .replaceAll(RegExp(r'^[•\-✓*]+\s*'), '')
          .replaceAll(RegExp(r'^\d+\.\s*'), '')
          .trim();

      // Remove asterisks used for markdown bold
      cleanedLine = cleanedLine.replaceAll('**', '').replaceAll('*', '');

      if (cleanedLine.isNotEmpty) {
        bulletPoints.add(cleanedLine);
      }
    }

    return bulletPoints.isEmpty ? [content] : bulletPoints;
  }

  /// Build individual section card
  Widget _buildSectionCard(
    BuildContext context,
    String title,
    String content,
    IconData icon, {
    Color? headerColor,
  }) {
    if (content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final bulletPoints = _parseToBulletPoints(content);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(0),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              (headerColor ?? AppColors.orange).withAlpha((0.05 * 255).toInt()),
              (headerColor ?? AppColors.orange).withAlpha((0.02 * 255).toInt()),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: (headerColor ?? AppColors.orange).withAlpha(
              (0.3 * 255).toInt(),
            ),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: (headerColor ?? AppColors.orange).withAlpha(
                (0.1 * 255).toInt(),
              ),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section Header with Icon
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: (headerColor ?? AppColors.orange).withAlpha(
                  (0.2 * 255).toInt(),
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: headerColor ?? AppColors.darkOrange,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: headerColor ?? AppColors.darkOrange,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            // Section Content - Bullet Points
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: bulletPoints
                    .map(
                      (point) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 12, top: 6),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: headerColor ?? AppColors.darkOrange,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                point,
                                style: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.copyWith(height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 4. Builds the description section
  /// Helper method to parse and format description text with proper structure, headers, bold, and bullets
  /// [Deprecated] - Kept for future implementation
  // ignore: unused_element
  List<TextSpan> _formatDescriptionText(String text) {
    final List<TextSpan> spans = [];

    // Remove all asterisk variations and clean up
    String cleaned = text
        .replaceAll(RegExp(r'\*+'), '') // Remove all asterisks
        .replaceAll(RegExp(r'\*\*'), '') // Remove markdown bold markers
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        ) // Replace multiple spaces with single space
        .trim();

    // Split by lines while preserving structure
    final lines = cleaned.split('\n');

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) {
        spans.add(TextSpan(text: '\n'));
        continue;
      }

      // Check if this is a header (contains emojis or starts with # or all caps)
      if (_isHeader(trimmedLine)) {
        spans.add(
          TextSpan(
            text: trimmedLine,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: AppColors.darkOrange,
              height: 1.5,
            ),
          ),
        );
        spans.add(TextSpan(text: '\n'));
        continue;
      }

      // Check if this is a numbered list item
      final numberedMatch = RegExp(r'^(\d+\.)(.+)$').firstMatch(trimmedLine);
      if (numberedMatch != null) {
        final number = numberedMatch.group(1) ?? '';
        final content = (numberedMatch.group(2) ?? '').trim();

        spans.add(
          TextSpan(
            text: '$number ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.darkOrange,
            ),
          ),
        );

        // Process content (already cleaned of asterisks)
        spans.add(
          TextSpan(
            text: content,
            style: TextStyle(color: AppColors.black),
          ),
        );
        spans.add(TextSpan(text: '\n\n'));
        continue;
      }

      // Check if this is a bullet point
      if (trimmedLine.startsWith('•') ||
          trimmedLine.startsWith('-') ||
          trimmedLine.startsWith('✓')) {
        final bulletChar = trimmedLine[0];
        final content = trimmedLine.substring(1).trim();

        spans.add(
          TextSpan(
            text: '$bulletChar ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.darkOrange,
            ),
          ),
        );

        spans.add(
          TextSpan(
            text: content,
            style: TextStyle(color: AppColors.black),
          ),
        );
        spans.add(TextSpan(text: '\n'));
        continue;
      }

      // Regular line
      spans.add(
        TextSpan(
          text: trimmedLine,
          style: TextStyle(color: AppColors.black),
        ),
      );
      spans.add(TextSpan(text: '\n'));
    }

    return spans;
  }

  /// Helper to check if line is a header
  bool _isHeader(String line) {
    // Check for emoji + text pattern (section headers)
    if (RegExp(
      r'^[^a-zA-Z0-9]*[\p{Emoji}][^a-zA-Z0-9]*[A-Z]',
      unicode: true,
    ).hasMatch(line)) {
      return true;
    }
    // Check for markdown headers
    if (line.startsWith('#')) return true;
    // Check for all caps with minimum length
    if (line.length > 3 &&
        line == line.toUpperCase() &&
        line.contains(RegExp(r'[A-Z]{3,}'))) {
      return true;
    }
    return false;
  }

  /// Helper to add formatted content with bold markdown support
  /// [Deprecated] - Kept for future implementation
  // ignore: unused_element
  void _addFormattedContent(List<TextSpan> spans, String content) {
    // Already handled in _formatDescriptionText - no need for separate processing
    spans.add(
      TextSpan(
        text: content,
        style: TextStyle(color: AppColors.black),
      ),
    );
  }

  /// Parse description and split by days/hours
  /// [Deprecated] - Kept for future implementation
  // ignore: unused_element
  List<Map<String, String>> _parseDescriptionIntoDays(String description) {
    final List<Map<String, String>> daysList = [];

    // Pattern to match "Day X:" or "Hour X:" or "Day X -" or similar
    final dayPattern = RegExp(
      r'(?:^|\n)\s*(?:Day|day|DAY|Hour|hour|HOUR)\s*[\d]+\s*[:\-]?\s*',
      multiLine: true,
    );

    final splits = description.split(dayPattern);

    // Extract day/hour headers
    final matches = dayPattern.allMatches(description).toList();

    if (splits.isEmpty || (splits.length == 1 && matches.isEmpty)) {
      // No day/hour pattern found, return whole description as single item
      return [
        {'title': 'Trip Overview', 'content': description.trim()},
      ];
    }

    // Process splits and matches together
    for (int i = 0; i < splits.length; i++) {
      final content = splits[i].trim();

      if (content.isEmpty) continue;

      String title = 'Day ${i + 1}';

      // Try to extract day number from original matches if available
      if (i < matches.length) {
        final matchText = matches[i].group(0) ?? '';
        final numberMatch = RegExp(r'[\d]+').firstMatch(matchText);
        if (numberMatch != null) {
          final number = numberMatch.group(0);
          if (matchText.toLowerCase().contains('hour')) {
            title = 'Hour $number';
          } else {
            title = 'Day $number';
          }
        }
      }

      daysList.add({'title': title, 'content': content});
    }

    return daysList.isNotEmpty
        ? daysList
        : [
            {'title': 'Trip Overview', 'content': description.trim()},
          ];
  }

  Widget _buildDescriptionSection(BuildContext context, TravelPlan plan) {
    // Define color palette for different card types
    final cardColors = {
      'day': const Color(0xFF8B4BA8), // Deep Purple for days
      'places': const Color(0xFFE91E63), // Pink for places
      'budget': const Color(0xFF8BC34A), // Light Green for budget
      'route': const Color(0xFF2196F3), // Blue for route
      'transport': const Color(0xFFFF5722), // Orange for transport
      'hotels': const Color(0xFF4CAF50), // Green for hotels
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Complete Travel Plan',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),

          // ===== Cards 1-5: DAY-WISE DETAILED PLANS =====
          if (plan.dayWisePlans.isNotEmpty)
            ...plan.dayWisePlans.asMap().entries.map((entry) {
              final index = entry.key;
              final dayPlan = entry.value;
              final dayNumber = index + 1;

              // Cycling color palette for each day
              final dayColors = [
                const Color(0xFF8B4BA8), // Deep Purple
                const Color(0xFF9B5FB8), // Purple
                const Color(0xFFB87DD8), // Light Purple
                const Color(0xFFC9ADE0), // Lighter Purple
                const Color(0xFF7B3FA0), // Darker Purple
              ];

              final dayColor = dayColors[index % dayColors.length];

              return _buildSectionCard(
                context,
                'Day $dayNumber',
                dayPlan,
                Icons.event_available,
                headerColor: dayColor,
              );
            }).toList(),

          // ===== Card 6: PLACES TO VISIT =====
          if (plan.placesList.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
              context,
              '📍 Places to Visit',
              plan.placesList,
              Icons.location_on,
              headerColor: cardColors['places']!,
            ),
          ],

          // ===== Card 7: DAY-WISE BUDGET EXPENSE =====
          if (plan.dayWiseBudget.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
              context,
              '💰 Day-wise Budget Expense',
              plan.dayWiseBudget,
              Icons.attach_money,
              headerColor: cardColors['budget']!,
            ),
          ],

          // ===== Card 8: TRAVEL ROUTE PROGRESSION =====
          if (plan.travelRoute.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
              context,
              '🛤️ Travel Route Progression',
              plan.travelRoute,
              Icons.directions_walk,
              headerColor: cardColors['route']!,
            ),
          ],

          // ===== Card 9: TRANSPORTATION COMPARISON TABLE =====
          if (plan.transportation.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
              context,
              '🚌 Transportation Comparison',
              plan.transportation,
              Icons.domain,
              headerColor: cardColors['transport']!,
            ),
          ],

          // ===== Card 10: HOTELS AND RESTAURANTS =====
          if (plan.hotelsRestaurants.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
              context,
              '🏨 Hotels & Restaurants',
              plan.hotelsRestaurants,
              Icons.restaurant,
              headerColor: cardColors['hotels']!,
            ),
          ],
        ],
      ),
    );
  }

  /// 5. Builds the reviews marquee section showing user reviews in a horizontal scroll
  Widget _buildReviewsMarqueeSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('User Reviews', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: _firestoreService.getReviewsForPlan(widget.planId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text('Error: ${snapshot.error}');
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(height: 200, child: LoadingWidget());
              }

              var reviews = snapshot.data?.docs ?? [];

              // Sort reviews by creation date (newest first)
              reviews.sort((a, b) {
                final dateA =
                    (a['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
                final dateB =
                    (b['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
                return dateB.compareTo(dateA);
              });

              if (reviews.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.veryLightGrey,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.lightGrey),
                  ),
                  child: Center(
                    child: Text(
                      'No reviews yet. Be the first to share your experience!',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: AppColors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              return SizedBox(
                height: 220,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: reviews.map((doc) {
                      final review = ReviewModel.fromMap({
                        ...doc.data() as Map<String, dynamic>,
                        'reviewId': doc.id,
                      });
                      return _buildReviewCard(context, review);
                    }).toList(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 6. Helper method to build individual review card for the marquee
  Widget _buildReviewCard(BuildContext context, ReviewModel review) {
    return Container(
      width: 300,
      margin: const EdgeInsets.only(right: 12),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // User info and rating
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          review.userName,
                          style: Theme.of(context).textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        RatingWidget(
                          rating: review.rating,
                          readOnly: true,
                          itemSize: 14,
                        ),
                      ],
                    ),
                  ),
                  if (review.userPhotoUrl != null &&
                      review.userPhotoUrl!.isNotEmpty)
                    CircleAvatar(
                      radius: 20,
                      backgroundImage: CachedNetworkImageProvider(
                        review.userPhotoUrl!,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Review comment
              Expanded(
                child: Text(
                  review.comment,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 8),
              // Date
              Text(
                _formatReviewDate(review.createdAt),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: AppColors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Helper method to build highlight cards
  Widget _buildHighlightCard(IconData icon, String label, String value) {
    return Expanded(
      child: Card(
        color: AppColors.veryLightGrey,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.darkOrange, size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                style: Theme.of(
                  this.context,
                ).textTheme.labelSmall?.copyWith(color: AppColors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(this.context).textTheme.titleSmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Helper method to format review date
  String _formatReviewDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        return '${difference.inMinutes} min ago';
      }
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 30) {
      return '${difference.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
