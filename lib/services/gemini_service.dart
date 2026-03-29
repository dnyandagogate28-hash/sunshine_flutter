import 'package:google_generative_ai/google_generative_ai.dart';
import 'dart:convert';
import '../config/env_config.dart';

class GeminiService {
  late final String apiKey;
  static const int MAX_RETRIES = 3;
  static const int INITIAL_DELAY_MS = 2000;
  late final GenerativeModel _model;

  GeminiService() {
    apiKey = EnvConfig.geminiApiKey;
    _model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);
  }

  /// Retry logic with exponential backoff for rate limiting
  Future<String> _retryWithBackoff(
    Future<String> Function() operation, {
    int retryCount = 0,
  }) async {
    try {
      return await operation();
    } catch (e) {
      final errorStr = e.toString();

      // Check if it's a rate limiting error (429 or "Resource exhausted")
      final isRateLimitError =
          errorStr.contains('429') ||
          errorStr.contains('Resource exhausted') ||
          errorStr.contains('RESOURCE_EXHAUSTED');

      if (isRateLimitError && retryCount < MAX_RETRIES) {
        // Calculate exponential backoff: 2s, 4s, 8s
        final delayMs = INITIAL_DELAY_MS * (1 << retryCount);
        print(
          'Rate limited. Retrying in ${delayMs}ms (attempt ${retryCount + 1}/$MAX_RETRIES)',
        );

        await Future.delayed(Duration(milliseconds: delayMs));
        return _retryWithBackoff(operation, retryCount: retryCount + 1);
      } else if (isRateLimitError) {
        // Max retries exceeded
        throw "API rate limit exceeded. Please wait a few moments and try again.";
      } else {
        rethrow;
      }
    }
  }

  /// Generate a detailed travel plan using Gemini AI
  Future<String> generateTravelPlan({
    required String startLocation,
    required String destination,
    required double budgetINR,
    required int durationDays,
    required int numberOfPassengers,
  }) async {
    final perPersonBudget = budgetINR / numberOfPassengers;
    final prompt =
        '''
Create a DETAILED and COMPREHENSIVE travel itinerary with the following specifications:
- Starting Location: $startLocation
- Destination: $destination
- Total Budget: ₹$budgetINR (For all $numberOfPassengers passengers)
- Per Person Budget: ₹$perPersonBudget
- Duration: $durationDays days
- Number of Passengers: $numberOfPassengers

===== SECTION 1: TRAVEL OPTIONS FROM $startLocation TO $destination =====

For each transport mode, provide:
- Mode of Transport (Flight/Train/Bus)
- Operator/Company Name
- Route Details
- Departure Time from $startLocation
- Arrival Time at $destination
- Travel Duration
- Cost per person
- Comfort Level & Facilities
- Nearby Tourist Spots on the Route
- Scheduled Stops/Attractions en route

Provide 3 different options (Flight, Train, Bus) with complete details.

===== SECTION 2: DAY-BY-DAY DETAILED ITINERARY =====

For each day (Day 1 to Day $durationDays), provide:

🌅 MORNING:
- Time: [Specific time range]
- Activity: [Detailed description]
- Location/Place: [Specific location name]
- What to Do/Explore: [Detailed activities and experiences]
- Cost per person: ₹[Amount]

🌞 AFTERNOON:
- Time: [Specific time range]
- Activity: [Detailed description]
- Location/Place: [Specific location name]
- What to Do/Explore: [Detailed activities and experiences]
- Food Options: [Specific restaurants with prices]
- Cost per person: ₹[Amount]

🌅 EVENING:
- Time: [Specific time range]
- Activity: [Detailed description]
- Location/Place: [Specific location name]
- What to Do/Explore: [Detailed activities and entertainment]
- Dining Recommendations: [Specific restaurants with prices]
- Cost per person: ₹[Amount]

✨ NIGHT/SPECIAL ACTIVITIES (if applicable):
- Activity: [Description]
- Timing: [Time]
- Location: [Place name]
- Cost per person: ₹[Amount]

===== SECTION 3: ATTRACTIONS & PLACES TO EXPLORE =====

For each major attraction, provide:
📍 [ATTRACTION NAME]
- Location: [Specific address/area]
- Distance from main location: [Distance in km]
- Opening Hours: [Timings]
- Entry Fee: ₹[Per person cost]
- Travel Time from last location: [Time required]
- What to Do There:
  ✓ [Activity 1] - Duration: [Time] - Cost: ₹[Amount]
  ✓ [Activity 2] - Duration: [Time] - Cost: ₹[Amount]
  ✓ [Activity 3] - Duration: [Time] - Cost: ₹[Amount]
- Must-try experiences
- Photography spots
- Best time to visit
- Recommended duration: [Time needed]

===== SECTION 4: FOOD & DINING GUIDE =====

For different meal types, suggest:
🍽️ [RESTAURANT/FOOD STALL NAME]
- Cuisine Type: [Type]
- Price per person: ₹[Amount]
- Must-try dishes: [List dishes]
- Location: [Address]
- Rating/Reviews: [Summary]

===== SECTION 5: ACCOMMODATION RECOMMENDATIONS =====

For each night:
🏨 [HOTEL NAME]
- Category: [Budget/Mid-range/Luxury]
- Price for $numberOfPassengers persons: ₹[Total]
- Room Type: [Double/Multi-bed]
- Amenities: [List included facilities]
- Location: [Area name]
- Nearest attractions: [List nearby places]
- Distance to main attractions: [Distances]

===== SECTION 6: COMPLETE BUDGET BREAKDOWN =====

Calculate for $numberOfPassengers passengers over $durationDays days:

💰 TRANSPORT (from $startLocation to $destination):
- [Chosen mode]: ₹[Total cost]
- Per person: ₹[Amount]

🏨 ACCOMMODATION (For $numberOfPassengers persons):
- [Number] nights: ₹[Total cost]
- Per person total: ₹[Amount]

🍽️ FOOD & DINING:
- Meals for $numberOfPassengers persons for $durationDays days: ₹[Total]
- Per person: ₹[Amount]
- Breakdown: Breakfast ₹[X], Lunch ₹[Y], Dinner ₹[Z] per day per person

🎫 ACTIVITIES & ATTRACTIONS:
- [Activity name]: ₹[Total] (₹[Per person])
- [Activity name]: ₹[Total] (₹[Per person])
- [Activity name]: ₹[Total] (₹[Per person])
- Total Activities Cost: ₹[Grand total]

🚕 LOCAL TRANSPORTATION:
- Taxis/Autos during stay: ₹[Total]
- Per person: ₹[Amount]

🎁 SHOPPING & MISCELLANEOUS:
- Average expected: ₹[Amount]
- Per person: ₹[Amount]

📊 FINAL SUMMARY:
Total Budget Allocated: ₹$budgetINR
Total Estimated Cost: ₹[Amount]
Savings/Surplus: ₹[Amount]
Per Person Total: ₹$perPersonBudget

===== SECTION 7: PRACTICAL INFORMATION =====

💡 TRAVEL TIPS:
- Best mode of transport: [Recommendation with reasoning]
- Local transport options in $destination
- Peak hours to avoid
- Best time to visit attractions
- Money-saving tips

📞 IMPORTANT CONTACTS:
- Emergency helpline
- Nearest hospital
- Local tourism office
- Police station

📋 PACKING ESSENTIALS:
- Weather-appropriate clothing
- Important documents
- Emergency items

⚠️ SAFETY PRECAUTIONS:
- Important safety tips
- Areas to avoid
- Travel insurance recommendations
- Local customs and etiquette

===== FORMATTING INSTRUCTIONS =====
- Use clear section headers with emojis
- Use "✓" for checkmarks
- Use "•" for bullet points
- Use "⏰" for timing
- Use "💰" for costs
- Use "---" to separate sections
- Bold important information: **text**
- Use line breaks extensively for mobile readability
- Be specific with numbers, names, and timings
- Provide realistic and detailed costs
- Make content actionable and practical

IMPORTANT: Be as SPECIFIC as possible with:
- Real transport company names (if applicable)
- Actual landmark/attraction names
- Realistic travel timings
- Realistic costs based on the destination
- Real restaurant/hotel names (if applicable)
- Specific activity recommendations with durations
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "Unable to generate travel plan";
      });
      return response;
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('rate limit') ||
          errorStr.contains('Resource exhausted') ||
          errorStr.contains('429')) {
        throw "The AI service is currently busy. Please wait a moment and try again.";
      } else if (errorStr.contains('API key')) {
        throw "API configuration error. Please contact support.";
      } else {
        throw "Error generating travel plan: $errorStr";
      }
    }
  }

  /// Generate chatbot responses for FAQ
  Future<String> generateChatbotResponse(String userQuery) async {
    final prompt =
        '''
You are a helpful travel assistant chatbot. Answer the following travel-related question clearly and concisely:

Question: $userQuery

Provide a helpful, informative response in 2-3 sentences.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "I'm unable to answer that question right now.";
      });
      return response;
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('rate limit') ||
          errorStr.contains('Resource exhausted')) {
        return "The service is busy. Please try again in a moment.";
      } else {
        return "Error: Unable to process your question. Please try again.";
      }
    }
  }

  /// Extract popular places from travel plan description
  Future<List<String>> extractPopularPlaces(String travelPlanText) async {
    final prompt =
        '''
From the following travel plan text, extract all tourist attractions and popular places to visit.
Return only a comma-separated list of place names without any additional text.

Travel Plan:
$travelPlanText
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "";
      });

      return response
          .split(',')
          .map((place) => place.trim())
          .where((place) => place.isNotEmpty)
          .toList();
    } catch (e) {
      print('Error extracting popular places: $e');
      return [];
    }
  }

  /// Extract place details (name, description, category) from travel plan
  Future<List<Map<String, dynamic>>> extractPlaceDetails(
    String travelPlanText,
    String destination,
  ) async {
    final prompt =
        '''
From the following travel plan for $destination, extract all tourist attractions and popular places to visit.

For each place, provide:
1. Place name
2. Brief description (1-2 sentences)
3. Category (temple, beach, restaurant, museum, market, natural, etc)

Format as JSON array like this (NO OTHER TEXT):
[
  {"name": "Place Name", "description": "Description here", "category": "temple"},
  {"name": "Another Place", "description": "Description", "category": "beach"}
]

Travel Plan:
$travelPlanText
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "";
      });

      // Try to parse as JSON
      if (response.isEmpty) return [];

      try {
        // Extract JSON from response (in case Gemini adds extra text)
        final jsonStart = response.indexOf('[');
        final jsonEnd = response.lastIndexOf(']');

        if (jsonStart == -1 || jsonEnd == -1) {
          print('No JSON found in response');
          return [];
        }

        final jsonStr = response.substring(jsonStart, jsonEnd + 1);
        final json = jsonDecode(jsonStr) as List<dynamic>;

        var places = json
            .whereType<Map<String, dynamic>>()
            .map(
              (place) => {
                'name': place['name'] ?? 'Unknown Place',
                'description': place['description'] ?? 'Popular attraction',
                'category': place['category'] ?? 'attraction',
              },
            )
            .toList();

        // Fetch image URLs for each place
        for (int i = 0; i < places.length; i++) {
          final placeName = places[i]['name'] as String;
          final imageUrl = await _fetchPlaceImageUrl(placeName, destination);
          if (imageUrl != null) {
            places[i]['imageUrl'] = imageUrl;
          }
        }

        return places;
      } catch (parseError) {
        print('Error parsing place JSON: $parseError');
        return [];
      }
    } catch (e) {
      print('Error extracting place details: $e');
      return [];
    }
  }

  /// Dynamically fetch image URL for a place using Picsum API (more reliable than Unsplash)
  Future<String?> _fetchPlaceImageUrl(
    String placeName,
    String destination,
  ) async {
    try {
      final cleanName = placeName.toLowerCase().trim();

      // Generate deterministic image ID based on place name hash
      // Using Picsum.photos which is more reliable than Unsplash
      final placeHash = cleanName.hashCode.abs();
      final imageUrl =
          'https://picsum.photos/600/400?random=${placeHash % 100}';

      print('🖼️ Dynamically fetching image for: $placeName');
      print('   Place name: $cleanName');
      print('   URL: $imageUrl');

      return imageUrl;
    } catch (e) {
      print('Error fetching image for $placeName: $e');
      return null;
    }
  }

  /// Generate recommendations based on user preferences
  Future<String> generatePersonalizedRecommendations({
    required String destination,
    required String interests, // e.g., "adventure, culture, food"
    required double budget,
    required int days,
  }) async {
    final prompt =
        '''
Based on the following preferences, provide personalized travel recommendations:
- Destination: $destination
- Interests: $interests
- Budget: ₹$budget
- Duration: $days days

Suggest activities, restaurants, and places that match these interests and budget.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "Unable to generate recommendations";
      });
      return response;
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('rate limit') ||
          errorStr.contains('Resource exhausted')) {
        throw "The service is busy. Please wait a moment and try again.";
      } else {
        throw "Error generating recommendations: $errorStr";
      }
    }
  }

  /// Generate day-wise/hour-wise itinerary plans
  Future<List<String>> generateItineraryPlans({
    required String destination,
    required int durationDays,
    required int numberOfPassengers,
    required double budgetPerPerson,
  }) async {
    final prompt =
        '''
Create a detailed day-by-day itinerary for $destination for $durationDays days with $numberOfPassengers passengers.
Budget per person: ₹$budgetPerPerson per day.

IMPORTANT: Start each day with exactly this format:
Day 1:
Day 2:
Day 3:
etc.

For each day, provide:
- Morning Activity (8 AM - 12 PM): Location, what to do, cost per person
- Afternoon Activity (12 PM - 5 PM): Location, what to do, cost per person  
- Evening Activity (5 PM - 10 PM): Location, what to do, cost per person

Be specific with times, place names, and costs in INR.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "";
      });

      // Parse the response into individual day plans
      final List<String> dayPlans = [];
      final days = response.split(RegExp(r'Day \d+:'));

      for (int i = 1; i < days.length; i++) {
        final dayContent = days[i].trim();
        if (dayContent.isNotEmpty) {
          dayPlans.add('Day ${i}:\n$dayContent');
        }
      }

      return dayPlans.isNotEmpty ? dayPlans : [response];
    } catch (e) {
      throw "Error generating itinerary plans: $e";
    }
  }

  /// Generate places to visit at destination
  Future<String> generatePlacesToVisit({
    required String destination,
    required int durationDays,
    required double budgetPerPerson,
  }) async {
    final prompt =
        '''
Generate a comprehensive list of must-visit places and attractions in $destination for a $durationDays day trip
with a budget of ₹$budgetPerPerson per person.

Format each place exactly as follows:
📍 [PLACE NAME]
Location: [Full address]
Distance: [Km from city center]
Entry Fee: ₹[Amount per person]
Best Time to Visit: [Time of day/month]
Activities: 
  ✓ [Activity 1] - Duration: [Time] - Cost: ₹[Amount]
  ✓ [Activity 2] - Duration: [Time] - Cost: ₹[Amount]
Must-see spots: [Details]

Include 8-10 major attractions with complete details.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No places found";
      });
      return response;
    } catch (e) {
      throw "Error generating places to visit: $e";
    }
  }

  /// Generate accommodation and dining recommendations
  Future<String> generateAccommodationAndDining({
    required String destination,
    required int numberOfPassengers,
    required int durationDays,
    required double budgetPerPerson,
  }) async {
    final prompt =
        '''
Generate comprehensive accommodation and dining recommendations for $destination.
- Number of guests: $numberOfPassengers
- Duration: $durationDays days
- Budget per person: ₹$budgetPerPerson

HOTELS:
🏨 [HOTEL NAME]
- Category: [Budget/Mid-range/Luxury]
- Location: [Area/Address]
- Price: ₹[Per night for $numberOfPassengers people]
- Amenities: [List facilities]
- Distance to attractions: [Distances]

RESTAURANTS:
🍽️ [RESTAURANT NAME]
- Cuisine: [Type]
- Price per person: ₹[Amount]
- Must-try dishes: [List 3-4 dishes]
- Location: [Address]
- Rating: [Stars/Reviews]

Include 5-6 hotels and 8-10 restaurants with specific names, prices, and locations.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No recommendations found";
      });
      return response;
    } catch (e) {
      throw "Error generating accommodation and dining info: $e";
    }
  }

  /// Generate detailed budget breakdown
  Future<String> generateBudgetBreakdown({
    required String destination,
    required int numberOfPassengers,
    required int durationDays,
    required double totalBudget,
  }) async {
    final perPersonBudget = totalBudget / numberOfPassengers;
    final prompt =
        '''
Create a detailed budget breakdown for a $durationDays day trip to $destination.
- Total Budget: ₹$totalBudget (for $numberOfPassengers people)
- Per Person Budget: ₹$perPersonBudget
- Duration: $durationDays days

Break down into these categories with specific amounts:

✈️ TRANSPORTATION:
- Mode (Flight/Train/Bus): ₹[Amount]
- Per person: ₹[Amount]

🏨 ACCOMMODATION:
- $durationDays nights total: ₹[Amount]
- Per person: ₹[Amount]

🍽️ FOOD & DINING:
- Breakfast (per day): ₹[Amount per person]
- Lunch (per day): ₹[Amount per person]
- Dinner (per day): ₹[Amount per person]
- Total for $durationDays days: ₹[Amount]

🎫 ACTIVITIES & ATTRACTIONS:
- [Activity 1]: ₹[Amount]
- [Activity 2]: ₹[Amount]
- [Activity 3]: ₹[Amount]
- Total: ₹[Amount]

🚕 LOCAL TRANSPORT:
- Taxis/Autos: ₹[Amount]
- Per person: ₹[Amount]

🛍️ SHOPPING & MISCELLANEOUS:
- Average expected: ₹[Amount]

📊 FINAL SUMMARY:
Total Estimated Cost: ₹[Amount]
Remaining Budget: ₹[Amount]
Per Person Total: ₹[Amount]

Use realistic costs for the destination and be specific with numbers.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No budget info available";
      });
      return response;
    } catch (e) {
      throw "Error generating budget breakdown: $e";
    }
  }

  /// Generate transportation details
  Future<String> generateTransportationDetails({
    required String startLocation,
    required String destination,
    required int numberOfPassengers,
    required double budgetPerPerson,
  }) async {
    final prompt =
        '''
Generate detailed transportation options from $startLocation to $destination for $numberOfPassengers passengers.
Budget per person: ₹$budgetPerPerson

For each mode of transport, provide:

✈️ FLIGHT:
- Airline/Company: [Name]
- Departure from $startLocation: [Time]
- Arrival at $destination: [Time]
- Travel Duration: [Hours]
- Cost per person: ₹[Amount]
- Comfort: [Details about seats, meals, baggage]
- Frequency: [Daily/Weekly/etc]
- Booking tips: [Advice]

🚂 TRAIN:
- Train Name & Number: [Details]
- Class: [AC/Non-AC/Sleeper]
- Departure from $startLocation: [Time]
- Arrival at $destination: [Time]
- Travel Duration: [Hours]
- Cost per person: ₹[Amount]
- Route highlights: [Scenic spots]
- Facilities: [Food, comfort details]

🚌 BUS:
- Bus Company: [Name]
- Type: [AC/Non-AC/Sleeper]
- Departure from $startLocation: [Time]
- Arrival at $destination: [Time]
- Travel Duration: [Hours]
- Cost per person: ₹[Amount]
- Stops: [Major stops en route]
- Comfort level: [Facilities]

LOCAL TRANSPORT AT DESTINATION:
- Taxis/Autos: ₹[Cost per km]
- Public Transport: [Options and costs]
- Rental vehicles: ₹[Per day rates]

RECOMMENDATION:
Best option for budget: [Which mode]
Best option for comfort: [Which mode]
Best option for speed: [Which mode]

Be specific with company names, times, and realistic costs.
''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No transportation info available";
      });
      return response;
    } catch (e) {
      throw "Error generating transportation details: $e";
    }
  }

  /// Master method: Generate detailed travel plan with all 10 cards
  Future<Map<String, dynamic>> generateCompleteTravelPlan({
    required String startLocation,
    required String destination,
    required double budgetINR,
    required int durationDays,
    required int numberOfPassengers,
  }) async {
    final perPersonBudget = budgetINR / numberOfPassengers;
    final dailyBudgetPerPerson = perPersonBudget / durationDays;

    try {
      // Generate all 6 components in parallel
      final results = await Future.wait([
        _generateDayWisePlans(
          startLocation: startLocation,
          destination: destination,
          durationDays: durationDays,
          dailyBudgetPerPerson: dailyBudgetPerPerson,
        ),
        _generatePlacesListCard(
          destination: destination,
          durationDays: durationDays,
        ),
        _generateDayWiseBudgetExpense(
          budgetINR: budgetINR,
          durationDays: durationDays,
          numberOfPassengers: numberOfPassengers,
        ),
        _generateTravelRouteCard(
          startLocation: startLocation,
          destination: destination,
          durationDays: durationDays,
        ),
        _generateTransportationComparison(
          startLocation: startLocation,
          destination: destination,
          numberOfPassengers: numberOfPassengers,
        ),
        _generateHotelsAndRestaurants(
          destination: destination,
          durationDays: durationDays,
          budgetPerPerson: perPersonBudget,
        ),
      ]);

      return {
        'dayWisePlans': results[0] as List<String>, // Cards 1-5
        'placesList': results[1] as String, // Card 6
        'dayWiseBudget': results[2] as String, // Card 7
        'travelRoute': results[3] as String, // Card 8
        'transportation': results[4] as String, // Card 9
        'hotelsRestaurants': results[5] as String, // Card 10
      };
    } catch (e) {
      throw "Error generating detailed travel plan: $e";
    }
  }

  /// Card 1-5: Generate day-wise detailed plans
  Future<List<String>> _generateDayWisePlans({
    required String startLocation,
    required String destination,
    required int durationDays,
    required double dailyBudgetPerPerson,
  }) async {
    final prompt =
        '''You are a travel planner. Create a detailed day-by-day itinerary from $startLocation to $destination for $durationDays days.
Budget per person per day: ₹$dailyBudgetPerPerson

Generate EXACTLY $durationDays separate day plans. For EACH day provide:

Day [number]:

✅ MORNING (8:00 AM - 12:00 PM):
Location: [Specific place name in $destination area]
Activities: [What to do - be specific]
Food: [Where to eat - specific restaurant name]
Budget: ₹[realistic amount]

🌞 AFTERNOON (12:00 PM - 5:00 PM):
Location: [Specific place name]
Activities: [Activities - be specific]
Food: [Specific restaurant/food place]
Budget: ₹[realistic amount]

🌅 EVENING (5:00 PM - 10:00 PM):
Location: [Specific place name]
Activities: [Entertainment/relaxation]
Food: [Dining option]
Budget: ₹[realistic amount]

🏨 STAY:
Hotel: [Specific hotel name in $destination]
Location: [Area/neighborhood]
Budget: ₹[Per person cost for room]

💰 DAY TOTAL: ₹[Add all amounts for the day]

---

IMPORTANT: Use REAL place names and restaurants in $destination. Be very specific and detailed. Generate complete information for every single day.''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "";
      });

      // Parse into individual day cards
      final List<String> dayPlans = [];

      // Split by "Day" pattern
      final dayBlocks = response.split(RegExp(r'(?=Day\s+\d+:)'));

      for (final block in dayBlocks) {
        final trimmed = block.trim();
        if (trimmed.isNotEmpty && trimmed.toLowerCase().startsWith('day')) {
          dayPlans.add(trimmed);
        }
      }

      // If parsing didn't work, return full response
      if (dayPlans.isEmpty) {
        dayPlans.add(response);
      }

      return dayPlans;
    } catch (e) {
      throw "Error generating day-wise plans: $e";
    }
  }

  /// Card 6: Generate list of places to visit
  Future<String> _generatePlacesListCard({
    required String destination,
    required int durationDays,
  }) async {
    final prompt =
        '''Generate a simple list of must-visit places in $destination for a $durationDays day trip.

Format EXACTLY as a numbered list:

PLACES TO VISIT IN $destination:

1. [Specific place name]
2. [Specific place name]
3. [Specific place name]
4. [Specific place name]
5. [Specific place name]
6. [Specific place name]
7. [Specific place name]
8. [Specific place name]

Generate 8-10 real, specific place names in $destination. Only place names, numbered.''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No places found";
      });
      return response;
    } catch (e) {
      throw "Error generating places list: $e";
    }
  }

  /// Card 7: Generate day-wise budget expense breakdown
  Future<String> _generateDayWiseBudgetExpense({
    required double budgetINR,
    required int durationDays,
    required int numberOfPassengers,
  }) async {
    final perPersonTotal = budgetINR / numberOfPassengers;
    final perPersonPerDay = perPersonTotal / durationDays;

    final prompt =
        '''Create a simple day-wise budget table for a $durationDays day trip.
Total Budget: ₹$budgetINR for $numberOfPassengers persons
Per Person Per Day: ₹$perPersonPerDay

Generate EXACTLY as a simple table:

DAY-WISE BUDGET BREAKDOWN (Per Person):

Day 1: ₹${perPersonPerDay.toStringAsFixed(0)}
Day 2: ₹${perPersonPerDay.toStringAsFixed(0)}
Day 3: ₹${perPersonPerDay.toStringAsFixed(0)}
Day 4: ₹${perPersonPerDay.toStringAsFixed(0)}
Day 5: ₹${perPersonPerDay.toStringAsFixed(0)}

Total Expense (Per Person): ₹$perPersonTotal
Total Expense ($numberOfPassengers persons): ₹$budgetINR

BREAKDOWN BY CATEGORY:
🍽️ Food: ₹[30% of daily budget]
🎫 Activities: ₹[25% of daily budget]
🏨 Accommodation: ₹[35% of daily budget]
🚕 Transport: ₹[10% of daily budget]''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No budget info";
      });
      return response;
    } catch (e) {
      throw "Error generating budget breakdown: $e";
    }
  }

  /// Card 8: Generate travel route progression
  Future<String> _generateTravelRouteCard({
    required String startLocation,
    required String destination,
    required int durationDays,
  }) async {
    final prompt =
        '''Create a travel route table for a $durationDays day trip from $startLocation to $destination.

Generate EXACTLY as a table:

TRAVEL ROUTE PROGRESSION:

| Day | Starting Point | Ending Point |
|---|---|---|
| Day 1 | $startLocation | [First major city/place on route] |
| Day 2 | [First place] | [Second place] |
| Day 3 | [Second place] | [Third place] |
| Day 4 | [Third place] | [Fourth place] |
| Day 5 | [Fourth place] | $destination |

Use real city/place names on the actual route from $startLocation to $destination.''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "Route info not available";
      });
      return response;
    } catch (e) {
      throw "Error generating travel route: $e";
    }
  }

  /// Card 9: Generate transportation comparison table
  Future<String> _generateTransportationComparison({
    required String startLocation,
    required String destination,
    required int numberOfPassengers,
  }) async {
    final prompt =
        '''Create a transportation comparison table from $startLocation to $destination.

Generate EXACTLY as a table:

TRANSPORTATION DETAILS:

| Category | Name | Departure | Arrival | Cost/Person | Duration |
|---|---|---|---|---|---|
| Flight | [Airline name] | [Time] | [Time] | ₹[Amount] | [Hours] |
| Bus | [Bus company name] | [Time] | [Time] | ₹[Amount] | [Hours] |
| Train | [Train name] | [Time] | [Time] | ₹[Amount] | [Hours] |

Use realistic times, company names, and costs for the $startLocation to $destination route.''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "Transport info not available";
      });
      return response;
    } catch (e) {
      throw "Error generating transportation comparison: $e";
    }
  }

  /// Card 10: Generate hotels and restaurants list
  Future<String> _generateHotelsAndRestaurants({
    required String destination,
    required int durationDays,
    required double budgetPerPerson,
  }) async {
    final prompt =
        '''Generate hotels and restaurants table for $destination.

Generate EXACTLY as a table:

HOTELS IN $destination:

| Sr No | Hotel Name | Available Time | Nearest Visiting Point | Price |
|---|---|---|---|---|
| 1 | [Real hotel name] | [Check-in to check-out time] | [Nearby attraction] | ₹[Per night] |
| 2 | [Real hotel name] | [Check-in to check-out time] | [Nearby attraction] | ₹[Per night] |
| 3 | [Real hotel name] | [Check-in to check-out time] | [Nearby attraction] | ₹[Per night] |
| 4 | [Real hotel name] | [Check-in to check-out time] | [Nearby attraction] | ₹[Per night] |
| 5 | [Real hotel name] | [Check-in to check-out time] | [Nearby attraction] | ₹[Per night] |

RESTAURANTS IN $destination:

| Sr No | Restaurant Name | Cuisine | Location | Distance | Price/Person |
|---|---|---|---|---|---|
| 1 | [Real restaurant name] | [Type] | [Area] | [Km] | ₹[Amount] |
| 2 | [Real restaurant name] | [Type] | [Area] | [Km] | ₹[Amount] |
| 3 | [Real restaurant name] | [Type] | [Area] | [Km] | ₹[Amount] |
| 4 | [Real restaurant name] | [Type] | [Area] | [Km] | ₹[Amount] |
| 5 | [Real restaurant name] | [Type] | [Area] | [Km] | ₹[Amount] |

Use only REAL hotel and restaurant names in $destination.''';

    try {
      final response = await _retryWithBackoff(() async {
        final result = await _model.generateContent([Content.text(prompt)]);
        return result.text ?? "No recommendations";
      });
      return response;
    } catch (e) {
      throw "Error generating hotels and restaurants: $e";
    }
  }
}
