import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/travel_plan_model.dart';
import '../models/review_model.dart';
import '../models/user_model.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get _userId => _auth.currentUser?.uid ?? "";

  // ==================== TRAVEL PLANS ====================

  /// Save a new travel plan
  Future<String> saveTravelPlan(TravelPlan plan) async {
    try {
      final docRef = await _db.collection("travel_plans").add(plan.toMap());
      return docRef.id;
    } catch (e) {
      throw "Error saving travel plan: $e";
    }
  }

  /// Get all travel plans (for browse/search)
  Stream<QuerySnapshot> getAllTravelPlans() {
    return _db
        .collection("travel_plans")
        .orderBy("createdAt", descending: true)
        .snapshots();
  }

  /// Get user's created plans
  Stream<QuerySnapshot> getUserCreatedPlans() {
    return _db
        .collection("travel_plans")
        .where("userId", isEqualTo: _userId)
        .snapshots();
  }

  /// Get a single travel plan by ID
  Future<TravelPlan?> getTravelPlanById(String planId) async {
    try {
      final doc = await _db.collection("travel_plans").doc(planId).get();
      if (doc.exists) {
        return TravelPlan.fromMap({...doc.data()!, "id": doc.id});
      }
      return null;
    } catch (e) {
      throw "Error fetching travel plan: $e";
    }
  }

  /// Search travel plans by destination (case-insensitive)
  Stream<List<DocumentSnapshot>> searchTravelPlansByDestination(String query) {
    final lowercaseQuery = query.toLowerCase();
    return _db
        .collection("travel_plans")
        .orderBy("createdAt", descending: true)
        .snapshots()
        .map((snapshot) {
          // Client-side case-insensitive filtering
          return snapshot.docs
              .where(
                (doc) => (doc['destination'] as String).toLowerCase().contains(
                  lowercaseQuery,
                ),
              )
              .toList();
        });
  }

  /// Update travel plan
  Future<void> updateTravelPlan(String planId, TravelPlan plan) async {
    try {
      await _db.collection("travel_plans").doc(planId).update(plan.toMap());
    } catch (e) {
      throw "Error updating travel plan: $e";
    }
  }

  /// Delete travel plan
  Future<void> deleteTravelPlan(String planId) async {
    try {
      await _db.collection("travel_plans").doc(planId).delete();
    } catch (e) {
      throw "Error deleting travel plan: $e";
    }
  }

  // ==================== REVIEWS ====================

  /// Add a review to a travel plan
  Future<void> addReview(ReviewModel review) async {
    try {
      await _db.collection("reviews").doc(review.reviewId).set(review.toMap());

      // Update plan's review count and rating
      await _updatePlanReviewStats(review.planId);
    } catch (e) {
      throw "Error adding review: $e";
    }
  }

  /// Get all reviews for a plan
  Stream<QuerySnapshot> getReviewsForPlan(String planId) {
    return _db
        .collection("reviews")
        .where("planId", isEqualTo: planId)
        .snapshots();
  }

  /// Update a review
  Future<void> updateReview(ReviewModel review) async {
    try {
      await _db
          .collection("reviews")
          .doc(review.reviewId)
          .update(review.toMap());
      await _updatePlanReviewStats(review.planId);
    } catch (e) {
      throw "Error updating review: $e";
    }
  }

  /// Delete a review
  Future<void> deleteReview(String reviewId, String planId) async {
    try {
      await _db.collection("reviews").doc(reviewId).delete();
      await _updatePlanReviewStats(planId);
    } catch (e) {
      throw "Error deleting review: $e";
    }
  }

  /// Helper: Update plan review stats
  Future<void> _updatePlanReviewStats(String planId) async {
    try {
      final reviewsSnapshot = await _db
          .collection("reviews")
          .where("planId", isEqualTo: planId)
          .get();

      String? planUserId;
      double averageRating = 0;
      int reviewCount = 0;

      if (reviewsSnapshot.docs.isEmpty) {
        averageRating = 0;
        reviewCount = 0;
      } else {
        double totalRating = 0;
        for (var doc in reviewsSnapshot.docs) {
          totalRating += (doc['rating'] as num).toDouble();
        }

        averageRating = totalRating / reviewsSnapshot.docs.length;
        reviewCount = reviewsSnapshot.docs.length;
      }

      // Get the plan owner to update their user rating
      final planDoc = await _db.collection("travel_plans").doc(planId).get();
      if (planDoc.exists) {
        planUserId = planDoc['userId'] as String?;
      }

      // Update plan stats
      await _db.collection("travel_plans").doc(planId).update({
        "averageRating": averageRating,
        "reviewCount": reviewCount,
      });

      // Update user's overall rating if we found the plan owner
      if (planUserId != null && planUserId.isNotEmpty) {
        await _updateUserAverageRating(planUserId);
      }
    } catch (e) {
      throw "Error updating review stats: $e";
    }
  }

  // ==================== USERS ====================

  /// Create or update user profile
  Future<void> saveUserProfile(UserModel user) async {
    try {
      await _db.collection("users").doc(user.uid).set(user.toMap());
    } catch (e) {
      throw "Error saving user profile: $e";
    }
  }

  /// Get user profile
  Future<UserModel?> getUserProfile(String uid) async {
    try {
      final doc = await _db.collection("users").doc(uid).get();
      if (doc.exists) {
        return UserModel.fromMap({...doc.data()!, "uid": doc.id});
      }
      return null;
    } catch (e) {
      throw "Error fetching user profile: $e";
    }
  }

  /// Get current user profile
  Future<UserModel?> getCurrentUserProfile() async {
    if (_userId.isEmpty) return null;
    return getUserProfile(_userId);
  }

  /// Update user profile (name and bio)
  Future<void> updateUserProfile({
    required String userId,
    required String name,
    required String bio,
  }) async {
    try {
      await _db.collection("users").doc(userId).update({
        "name": name,
        "bio": bio,
      });
    } catch (e) {
      throw "Error updating user profile: $e";
    }
  }

  /// Add saved plan to user
  Future<void> savePlanToUser(String planId) async {
    try {
      await _db.collection("users").doc(_userId).update({
        "savedPlanIds": FieldValue.arrayUnion([planId]),
      });
    } catch (e) {
      throw "Error saving plan: $e";
    }
  }

  /// Remove saved plan from user
  Future<void> removeSavedPlan(String planId) async {
    try {
      await _db.collection("users").doc(_userId).update({
        "savedPlanIds": FieldValue.arrayRemove([planId]),
      });
    } catch (e) {
      throw "Error removing saved plan: $e";
    }
  }

  /// Add created plan to user
  Future<void> addCreatedPlanToUser(String planId) async {
    try {
      await _db.collection("users").doc(_userId).update({
        "createdPlanIds": FieldValue.arrayUnion([planId]),
      });
    } catch (e) {
      throw "Error adding created plan: $e";
    }
  }

  /// Update user last login
  Future<void> updateLastLogin() async {
    try {
      await _db.collection("users").doc(_userId).update({
        "lastLogin": Timestamp.now(),
      });
    } catch (e) {
      print("Error updating last login: $e");
    }
  }

  /// Update user's average rating based on all their plans
  Future<void> _updateUserAverageRating(String userId) async {
    try {
      // Get all plans created by this user
      final plansSnapshot = await _db
          .collection("travel_plans")
          .where("userId", isEqualTo: userId)
          .get();

      if (plansSnapshot.docs.isEmpty) {
        // No plans, set rating to 0
        await _db.collection("users").doc(userId).update({
          "averageRating": 0.0,
        });
        return;
      }

      // Calculate average rating across all user's plans
      double totalRating = 0;
      int planCount = 0;

      for (var planDoc in plansSnapshot.docs) {
        final planData = planDoc.data();
        final planRating = (planData["averageRating"] ?? 0).toDouble();
        final reviewCount = (planData["reviewCount"] ?? 0).toInt();

        // Only count plans that have reviews
        if (reviewCount > 0) {
          totalRating += planRating;
          planCount++;
        }
      }

      double userAverageRating = planCount > 0 ? totalRating / planCount : 0.0;

      await _db.collection("users").doc(userId).update({
        "averageRating": userAverageRating,
      });
    } catch (e) {
      print("Error updating user average rating: $e");
    }
  }

  // ==================== SEARCH & FILTER ====================

  /// Search plans by multiple criteria (client-side filtering for budget/duration)
  Stream<List<DocumentSnapshot>> searchPlans({
    String? destination,
    double? maxBudget,
    int? maxDuration,
  }) {
    Query query = _db.collection("travel_plans");

    if (destination != null && destination.isNotEmpty) {
      query = query
          .where("destination", isGreaterThanOrEqualTo: destination)
          .where("destination", isLessThan: '${destination}z');
    }

    return query.orderBy("createdAt", descending: true).snapshots().map((
      snapshot,
    ) {
      // Client-side filtering for budget and duration
      return snapshot.docs.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        if (maxBudget != null && (data['budget'] as num? ?? 0) > maxBudget) {
          return false;
        }
        if (maxDuration != null &&
            (data['duration'] as num? ?? 0) > maxDuration) {
          return false;
        }
        return true;
      }).toList();
    });
  }

  /// Get trending plans (high ratings, multiple reviews)
  Stream<QuerySnapshot> getTrendingPlans() {
    return _db
        .collection("travel_plans")
        .where("reviewCount", isGreaterThan: 0)
        .orderBy("reviewCount", descending: true)
        .limit(20)
        .snapshots();
  }
}
