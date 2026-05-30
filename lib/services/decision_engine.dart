import 'dart:developer' as developer;

import 'api_service.dart';
import 'db_service.dart';

class DecisionResult {
  final int contentId;
  final String title;
  final String channel;
  final String focusGoal;
  final double relevanceScore;
  final bool isProductive;
  final bool hasError;
  final String source;
  final bool fromCache;
  final int consecutiveUnproductiveCount;
  final int? interventionTier;

  const DecisionResult({
    required this.contentId,
    required this.title,
    required this.channel,
    required this.focusGoal,
    required this.relevanceScore,
    required this.isProductive,
    required this.hasError,
    required this.source,
    required this.fromCache,
    required this.consecutiveUnproductiveCount,
    this.interventionTier,
  });
}

class DecisionEngine {
  static final DecisionEngine _instance = DecisionEngine._internal();

  factory DecisionEngine() => _instance;

  DecisionEngine._internal();

  final DatabaseService _db = DatabaseService();
  int _consecutiveUnproductiveCount = 0;

  Future<DecisionResult> evaluateAndPersist({
    required int sessionId,
    required String title,
    required String channel,
    required String extractedText,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedChannel = channel.trim();
    final normalizedText = extractedText.trim();
    final displayTitle = normalizedTitle.isNotEmpty
        ? normalizedTitle
        : _compactTitle(normalizedText);

    final focusGoal = await _db.getFocusGoal();
    final contentHash = _contentHash(
      title: normalizedTitle,
      channel: normalizedChannel,
      extractedText: normalizedText,
      focusGoal: focusGoal,
    );

    final contentId = await _db.insertContent(
      sessionId,
      normalizedTitle,
      normalizedChannel,
      normalizedText,
    );

    final cached = await _db.getCachedVerdict(contentHash);
    if (cached != null) {
      final relevanceScore = _asDouble(cached['last_relevance_score']);
      final label = cached['last_label']?.toString() ?? 'unproductive';
      final isProductive = label == 'productive';

      await _db.insertVerdict(contentId, relevanceScore, isProductive);
      final interventionTier = await _updateInterventionState(
        sessionId: sessionId,
        isProductive: isProductive,
        hasError: false,
      );

      return DecisionResult(
        contentId: contentId,
        title: displayTitle,
        channel: normalizedChannel,
        focusGoal: focusGoal,
        relevanceScore: relevanceScore,
        isProductive: isProductive,
        hasError: false,
        source: 'cache',
        fromCache: true,
        consecutiveUnproductiveCount: _consecutiveUnproductiveCount,
        interventionTier: interventionTier,
      );
    }

    final apiResult = await ApiService.evaluateContent(
      title: normalizedTitle,
      channel: normalizedChannel,
      extractedText: normalizedText,
      focusGoal: focusGoal,
    );

    final isProductive = apiResult?['is_productive'] == true;
    final relevanceScore = _asDouble(apiResult?['relevance_score']);
    final source = apiResult?['source']?.toString() ?? 'api';
    final hasError = apiResult?['error'] == true;

    await _db.insertVerdict(contentId, relevanceScore, isProductive);

    if (!hasError) {
      await _db.upsertCachedVerdict(
        contentHash: contentHash,
        relevanceScore: relevanceScore,
        label: isProductive ? 'productive' : 'unproductive',
      );
    } else {
      developer.log(
        'Skipping cache write for offline/error verdict',
        name: 'DecisionEngine',
      );
    }

    final interventionTier = await _updateInterventionState(
      sessionId: sessionId,
      isProductive: isProductive,
      hasError: hasError,
    );

    return DecisionResult(
      contentId: contentId,
      title: displayTitle,
      channel: normalizedChannel,
      focusGoal: focusGoal,
      relevanceScore: relevanceScore,
      isProductive: isProductive,
      hasError: hasError,
      source: source,
      fromCache: false,
      consecutiveUnproductiveCount: _consecutiveUnproductiveCount,
      interventionTier: interventionTier,
    );
  }

  Future<int?> _updateInterventionState({
    required int sessionId,
    required bool isProductive,
    required bool hasError,
  }) async {
    if (hasError) return null;

    if (isProductive) {
      _consecutiveUnproductiveCount = 0;
      return null;
    }

    _consecutiveUnproductiveCount += 1;

    final tier = switch (_consecutiveUnproductiveCount) {
      1 => 1,
      3 => 2,
      >= 5 => 3,
      _ => null,
    };

    if (tier != null) {
      await _db.insertIntervention(sessionId, tier.toString());
    }

    return tier;
  }

  String _contentHash({
    required String title,
    required String channel,
    required String extractedText,
    required String focusGoal,
  }) {
    final input = [
      focusGoal.toLowerCase(),
      title.toLowerCase(),
      channel.toLowerCase(),
      extractedText.toLowerCase(),
    ].join('|');

    var hash = 0xcbf29ce484222325;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }

    return hash.toRadixString(16).padLeft(16, '0');
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  String _compactTitle(String text) {
    if (text.length <= 80) return text;
    return text.substring(0, 80);
  }
}
