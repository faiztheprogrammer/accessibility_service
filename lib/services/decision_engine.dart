import 'dart:developer' as developer;

import 'api_service.dart';
import 'auth_service.dart';
import 'behavior_model_service.dart';
import 'db_service.dart';

class DecisionResult {
  final int contentId;
  final String title;
  final String channel;
  final String focusGoal;
  final double relevanceScore;
  final double contentScore;
  final double behaviorRiskScore;
  final double finalRiskScore;
  final bool isProductive;
  final bool isBehaviorHighRisk;
  final bool hasError;
  final String source;
  final String decisionLabel;
  final String decisionReason;
  final bool fromCache;
  final int consecutiveUnproductiveCount;
  final int? interventionTier;

  const DecisionResult({
    required this.contentId,
    required this.title,
    required this.channel,
    required this.focusGoal,
    required this.relevanceScore,
    required this.contentScore,
    required this.behaviorRiskScore,
    required this.finalRiskScore,
    required this.isProductive,
    required this.isBehaviorHighRisk,
    required this.hasError,
    required this.source,
    required this.decisionLabel,
    required this.decisionReason,
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
  final BehaviorModelService _behaviorModel = BehaviorModelService();
  int _consecutiveUnproductiveCount = 0;

  Future<DecisionResult> evaluateAndPersist({
    required int sessionId,
    required String appName,
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

    final userId = await AuthService().currentUserId();
    final focusGoal = await _db.getFocusGoal(userId: userId);
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
      final behaviorRisk = await _behaviorModel.evaluate(
        sessionId: sessionId,
        appName: appName,
      );
      final fusion = _fuseDecision(
        contentScore: relevanceScore,
        contentProductive: isProductive,
        behaviorRiskScore: behaviorRisk.riskScore,
        behaviorHighRisk: behaviorRisk.isHighRisk,
        source: 'cache',
      );

      await _db.insertVerdict(
        contentId,
        relevanceScore,
        fusion.isProductive,
        contentScore: relevanceScore,
        behaviorRiskScore: behaviorRisk.riskScore,
        finalRiskScore: fusion.finalRiskScore,
        decisionLabel: fusion.label,
        decisionReason: fusion.reason,
        source: fusion.source,
      );
      final interventionTier = await _updateInterventionState(
        sessionId: sessionId,
        shouldCountAsDistraction: fusion.shouldCountAsDistraction,
        shouldResetDistractions: fusion.shouldResetDistractions,
        hasError: false,
      );

      return DecisionResult(
        contentId: contentId,
        title: displayTitle,
        channel: normalizedChannel,
        focusGoal: focusGoal,
        relevanceScore: relevanceScore,
        contentScore: relevanceScore,
        behaviorRiskScore: behaviorRisk.riskScore,
        finalRiskScore: fusion.finalRiskScore,
        isProductive: fusion.isProductive,
        isBehaviorHighRisk: behaviorRisk.isHighRisk,
        hasError: false,
        source: fusion.source,
        decisionLabel: fusion.label,
        decisionReason: fusion.reason,
        fromCache: true,
        consecutiveUnproductiveCount: _consecutiveUnproductiveCount,
        interventionTier: interventionTier,
      );
    }

    final apiResult = await ApiService.evaluateContent(
      title: normalizedTitle,
      channel: normalizedChannel,
      extractedText: normalizedText,
      appName: appName,
      focusGoal: focusGoal,
    );

    final isProductive = apiResult?['is_productive'] == true;
    final relevanceScore = _asDouble(apiResult?['relevance_score']);
    final source = apiResult?['source']?.toString() ?? 'api';
    final hasError = apiResult?['error'] == true;
    final behaviorRisk = await _behaviorModel.evaluate(
      sessionId: sessionId,
      appName: appName,
    );
    final fusion = _fuseDecision(
      contentScore: relevanceScore,
      contentProductive: isProductive,
      behaviorRiskScore: behaviorRisk.riskScore,
      behaviorHighRisk: behaviorRisk.isHighRisk,
      source: source,
    );

    await _db.insertVerdict(
      contentId,
      relevanceScore,
      fusion.isProductive,
      contentScore: relevanceScore,
      behaviorRiskScore: behaviorRisk.riskScore,
      finalRiskScore: fusion.finalRiskScore,
      decisionLabel: fusion.label,
      decisionReason: fusion.reason,
      source: fusion.source,
    );

    final shouldCacheVerdict = !hasError &&
        !source.contains('fallback') &&
        !source.contains('quota');

    if (shouldCacheVerdict) {
      await _db.upsertCachedVerdict(
        contentHash: contentHash,
        relevanceScore: relevanceScore,
        label: isProductive ? 'productive' : 'unproductive',
      );
    } else {
      developer.log(
        'Skipping cache write for offline/local fallback verdict',
        name: 'DecisionEngine',
      );
    }

    final interventionTier = await _updateInterventionState(
      sessionId: sessionId,
      shouldCountAsDistraction: fusion.shouldCountAsDistraction,
      shouldResetDistractions: fusion.shouldResetDistractions,
      hasError: hasError,
    );

    return DecisionResult(
      contentId: contentId,
      title: displayTitle,
      channel: normalizedChannel,
      focusGoal: focusGoal,
      relevanceScore: relevanceScore,
      contentScore: relevanceScore,
      behaviorRiskScore: behaviorRisk.riskScore,
      finalRiskScore: fusion.finalRiskScore,
      isProductive: fusion.isProductive,
      isBehaviorHighRisk: behaviorRisk.isHighRisk,
      hasError: hasError,
      source: fusion.source,
      decisionLabel: fusion.label,
      decisionReason: fusion.reason,
      fromCache: false,
      consecutiveUnproductiveCount: _consecutiveUnproductiveCount,
      interventionTier: interventionTier,
    );
  }

  Future<int?> _updateInterventionState({
    required int sessionId,
    required bool shouldCountAsDistraction,
    required bool shouldResetDistractions,
    required bool hasError,
  }) async {
    if (hasError) return null;

    if (shouldResetDistractions) {
      _consecutiveUnproductiveCount = 0;
      return null;
    }

    if (!shouldCountAsDistraction) return null;

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

  _FusionDecision _fuseDecision({
    required double contentScore,
    required bool contentProductive,
    required double behaviorRiskScore,
    required bool behaviorHighRisk,
    required String source,
  }) {
    final behaviorPenalty = _behaviorPenalty(
      contentScore: contentScore,
      behaviorRiskScore: behaviorRiskScore,
    );
    final contextualProductivityScore =
        (contentScore - behaviorPenalty).clamp(0.0, 1.0);
    final finalRiskScore =
        ((1 - contextualProductivityScore) * 0.75 + behaviorRiskScore * 0.25)
            .clamp(0.0, 1.0);
    final contextProductive = contextualProductivityScore >= 0.55;
    final sourceLabel = source == 'cache'
        ? 'cache + behavioral_model'
        : '$source + behavioral_model';

    if (contentProductive && !contextProductive) {
      return _FusionDecision(
        label: 'contextual_distraction',
        reason: 'Goal-adjacent content, but timing and session risk make it distracting now.',
        finalRiskScore: finalRiskScore,
        source: sourceLabel,
        isProductive: false,
        shouldCountAsDistraction: true,
        shouldResetDistractions: false,
      );
    }

    if (contentProductive && behaviorRiskScore >= 0.50) {
      return _FusionDecision(
        label: 'productive_high_risk',
        reason: 'Goal-aligned content, but behavior pattern suggests overuse.',
        finalRiskScore: finalRiskScore,
        source: sourceLabel,
        isProductive: true,
        shouldCountAsDistraction: false,
        shouldResetDistractions: behaviorRiskScore < 0.60,
      );
    }

    if (contentProductive) {
      return _FusionDecision(
        label: 'productive',
        reason: 'Content is aligned with the current goal.',
        finalRiskScore: finalRiskScore,
        source: sourceLabel,
        isProductive: true,
        shouldCountAsDistraction: false,
        shouldResetDistractions: true,
      );
    }

    if (behaviorRiskScore >= 0.45 || behaviorHighRisk) {
      return _FusionDecision(
        label: 'high_distraction_risk',
        reason: 'Unrelated content combined with risky usage behavior.',
        finalRiskScore: finalRiskScore,
        source: sourceLabel,
        isProductive: false,
        shouldCountAsDistraction: true,
        shouldResetDistractions: false,
      );
    }

    return _FusionDecision(
      label: 'possible_distraction',
      reason: 'Content appears unrelated to the current goal.',
      finalRiskScore: finalRiskScore,
      source: sourceLabel,
      isProductive: false,
      shouldCountAsDistraction: true,
      shouldResetDistractions: false,
    );
  }

  double _behaviorPenalty({
    required double contentScore,
    required double behaviorRiskScore,
  }) {
    if (contentScore >= 0.85) {
      return behaviorRiskScore >= 0.75 ? 0.05 : 0.0;
    }

    if (behaviorRiskScore >= 0.75) return 0.25;
    if (behaviorRiskScore >= 0.60) return 0.16;
    if (behaviorRiskScore >= 0.45) return 0.08;
    return 0.0;
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

class _FusionDecision {
  final String label;
  final String reason;
  final double finalRiskScore;
  final String source;
  final bool isProductive;
  final bool shouldCountAsDistraction;
  final bool shouldResetDistractions;

  const _FusionDecision({
    required this.label,
    required this.reason,
    required this.finalRiskScore,
    required this.source,
    required this.isProductive,
    required this.shouldCountAsDistraction,
    required this.shouldResetDistractions,
  });
}
