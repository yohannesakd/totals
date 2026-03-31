import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/models/category.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/providers/transaction_provider.dart';

Future<void> showTransactionCategorySheet({
  required BuildContext context,
  required Transaction transaction,
  required TransactionProvider provider,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _TransactionCategorySheet(
      transaction: transaction,
      provider: provider,
    ),
  );
}

class _TransactionCategorySheet extends StatefulWidget {
  final Transaction transaction;
  final TransactionProvider provider;

  const _TransactionCategorySheet({
    required this.transaction,
    required this.provider,
  });

  @override
  State<_TransactionCategorySheet> createState() =>
      _TransactionCategorySheetState();
}

class _TransactionCategorySheetState extends State<_TransactionCategorySheet> {
  bool _showNewCategoryForm = false;
  bool _showColorChoices = false;
  bool _isApplyingCategory = false;
  bool _autoCategorizeFutureTransactions = false;
  String _draftColorKey = _kCategoryColorOptions.first.key;
  final TextEditingController _newCategoryController = TextEditingController();
  final FocusNode _newCategoryFocus = FocusNode();
  final ScrollController _sheetScrollController = ScrollController();
  double _lastKeyboardInset = 0;

  Transaction get _tx => widget.transaction;
  TransactionProvider get _provider => widget.provider;

  bool get _isCredit => _tx.type == 'CREDIT';

  Category? get _currentCategory => _provider.getCategoryById(_tx.categoryId);
  String? get _autoCategorizationCounterparty =>
      _provider.resolvePrimaryCounterparty(_tx);

  bool get _canShowAutoCategorizationOption =>
      _provider.canConfigureAutoCategorizationForTransaction(_tx);

  @override
  void initState() {
    super.initState();
    _syncAutoCategorizationCheckbox();
  }

  List<Category> get _availableCategories {
    final desiredFlow = _isCredit ? 'income' : 'expense';
    final filtered = _provider.categories
        .where((category) => category.flow.toLowerCase() == desiredFlow)
        .toList(growable: false);
    final base = filtered.isEmpty ? _provider.categories : filtered;
    return base
        .where((category) => category.name.trim().toLowerCase() != 'self')
        .toList(growable: false);
  }

  void _syncAutoCategorizationCheckbox() {
    _autoCategorizeFutureTransactions =
        _provider.findAutoCategorizationRuleForTransaction(_tx) != null;
  }

  void _dismissComposerState({bool clearDraft = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    _newCategoryFocus.unfocus();
    if (!_showNewCategoryForm && !_showColorChoices && !clearDraft) return;
    if (!mounted) return;
    setState(() {
      _showNewCategoryForm = false;
      _showColorChoices = false;
      if (clearDraft) {
        _newCategoryController.clear();
      }
    });
  }

  Future<void> _setCategory(Category category) async {
    if (_isApplyingCategory || category.id == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final shouldAutoCategorize = _autoCategorizeFutureTransactions;
    final existingRule = _provider.findAutoCategorizationRuleForTransaction(_tx);
    if (_currentCategory?.id == category.id) {
      _dismissComposerState(clearDraft: true);
      final shouldSyncRule = shouldAutoCategorize
          ? existingRule?.categoryId != category.id
          : existingRule != null;
      if (!shouldSyncRule) {
        if (mounted) {
          Navigator.of(context).pop();
        }
        return;
      }
      _isApplyingCategory = true;
      Navigator.of(context).pop();
      unawaited(
        _completeCategorySelection(
          saveAction: () => Future<void>.value(),
          messenger: messenger,
          category: category,
          shouldAutoCategorize: shouldAutoCategorize,
        ),
      );
      return;
    }
    final sheetNavigator = Navigator.of(context);
    _dismissComposerState(clearDraft: true);
    _isApplyingCategory = true;
    sheetNavigator.pop();
    unawaited(
      _completeCategorySelection(
        saveAction: () => _provider.setCategoryForTransaction(_tx, category),
        messenger: messenger,
        category: category,
        shouldAutoCategorize: shouldAutoCategorize,
      ),
    );
  }

  Future<void> _clearCategory() async {
    if (_isApplyingCategory) return;
    _dismissComposerState(clearDraft: true);
    _isApplyingCategory = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    unawaited(
      _completeClearCategory(
        clearAction: () => _provider.clearCategoryForTransaction(_tx),
        messenger: messenger,
      ),
    );
  }

  Future<void> _completeCategorySelection({
    required Future<void> Function() saveAction,
    required ScaffoldMessengerState? messenger,
    required Category category,
    required bool shouldAutoCategorize,
  }) async {
    await SchedulerBinding.instance.endOfFrame;

    try {
      await saveAction();
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Could not update category. Changes were reverted.'),
        ),
      );
      return;
    }

    try {
      await _provider.syncAutoCategorizationRuleForSelection(
        transaction: _tx,
        category: category,
        shouldAutoCategorize: shouldAutoCategorize,
      );
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Category was saved, but auto-categorization could not be updated.',
          ),
        ),
      );
    }
  }

  Future<void> _completeClearCategory({
    required Future<void> Function() clearAction,
    required ScaffoldMessengerState? messenger,
  }) async {
    await SchedulerBinding.instance.endOfFrame;

    try {
      await clearAction();
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Could not clear category. Changes were reverted.'),
        ),
      );
    }
  }

  void _toggleNewCategoryForm() {
    final shouldShow = !_showNewCategoryForm;
    setState(() {
      _showNewCategoryForm = shouldShow;
      _showColorChoices = false;
      if (!shouldShow) {
        _newCategoryController.clear();
      }
    });
    if (!shouldShow) {
      _newCategoryFocus.unfocus();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _newCategoryFocus.requestFocus();
      _scrollComposerIntoView();
    });
  }

  void _toggleColorChoices() {
    final willOpen = !_showColorChoices;
    setState(() => _showColorChoices = willOpen);
    if (!willOpen) return;
    _scrollComposerIntoView();
  }

  void _scrollComposerIntoView() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheetScrollController.hasClients) return;
      final target = _sheetScrollController.position.maxScrollExtent;
      _sheetScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Category? _findCategoryByNameAndFlow({
    required String name,
    required String flow,
    Set<int>? excludeIds,
  }) {
    final normalizedName = name.trim().toLowerCase();
    final normalizedFlow = flow.toLowerCase();
    return _provider.categories
        .where((category) =>
            category.flow.toLowerCase() == normalizedFlow &&
            category.name.trim().toLowerCase() == normalizedName &&
            (category.id == null ||
                !(excludeIds?.contains(category.id) ?? false)))
        .fold<Category?>(
          null,
          (best, category) =>
              best == null || (category.id ?? 0) > (best.id ?? 0)
                  ? category
                  : best,
        );
  }

  bool _categoryExistsForFlow({
    required String name,
    required String flow,
  }) {
    return _findCategoryByNameAndFlow(name: name, flow: flow) != null;
  }

  String? _extractColorKey(String? iconKey) {
    if (iconKey == null || iconKey.isEmpty) return null;
    const prefix = 'color:';
    if (!iconKey.startsWith(prefix)) return null;
    final value = iconKey.substring(prefix.length).trim();
    if (value.isEmpty) return null;
    return value;
  }

  Color _colorFromKey(String colorKey) {
    for (final option in _kCategoryColorOptions) {
      if (option.key == colorKey) return option.color;
    }
    return _kCategoryColorOptions.first.color;
  }

  int _fallbackColorIndex(Category category) {
    final seed = '${category.flow}:${category.name.toLowerCase()}';
    int hash = 0;
    for (final code in seed.codeUnits) {
      hash = (hash + code) & 0x7fffffff;
    }
    return hash % _kCategoryColorOptions.length;
  }

  Future<void> _setSelfCategory() async {
    const selfName = 'Self';
    final flow = _isCredit ? 'income' : 'expense';
    final existing = _findCategoryByNameAndFlow(name: selfName, flow: flow);
    if (existing != null) {
      await _setCategory(existing);
      return;
    }

    final knownCategoryIds = _provider.categories
        .map((category) => category.id)
        .whereType<int>()
        .toSet();

    try {
      await _provider.createCategory(
        name: selfName,
        essential: false,
        flow: flow,
        colorKey: 'gray',
      );
    } catch (_) {
      if (!mounted) return;
    }

    final created = _findCategoryByNameAndFlow(
      name: selfName,
      flow: flow,
      excludeIds: knownCategoryIds,
    );
    final target =
        created ?? _findCategoryByNameAndFlow(name: selfName, flow: flow);
    if (target != null) {
      await _setCategory(target);
    }
  }

  Future<void> _createNewCategoryInline() async {
    final createdName = _newCategoryController.text.trim();
    if (createdName.isEmpty) return;
    final flow = _isCredit ? 'income' : 'expense';
    if (_categoryExistsForFlow(name: createdName, flow: flow)) {
      _newCategoryFocus.requestFocus();
      return;
    }
    final knownCategoryIds = _provider.categories
        .map((category) => category.id)
        .whereType<int>()
        .toSet();
    try {
      await _provider.createCategory(
        name: createdName,
        essential: false,
        flow: flow,
        colorKey: _draftColorKey,
      );
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().toLowerCase();
      if (message.contains('unique') ||
          message.contains('constraint') ||
          message.contains('already exists')) {
        _newCategoryFocus.requestFocus();
        setState(() {});
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create category')),
      );
      return;
    }
    if (!mounted) return;
    final createdCategory = _findCategoryByNameAndFlow(
      name: createdName,
      flow: flow,
      excludeIds: knownCategoryIds,
    );
    if (createdCategory != null) {
      await _setCategory(createdCategory);
      return;
    }
    setState(() {
      _showNewCategoryForm = false;
      _showColorChoices = false;
      _newCategoryController.clear();
    });
    _newCategoryFocus.unfocus();
  }

  @override
  void dispose() {
    _newCategoryController.dispose();
    _newCategoryFocus.dispose();
    _sheetScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentCategory = _currentCategory;
    final isLockedSelfTransfer = _provider.isDetectedSelfTransfer(_tx);
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final keyboardScrollBuffer = keyboardInset > 0 ? 88.0 : 24.0;
    final maxSheetHeight = mediaQuery.size.height *
        (_showNewCategoryForm || _showColorChoices ? 0.76 : 0.62);
    if (keyboardInset > _lastKeyboardInset && _showNewCategoryForm) {
      _scrollComposerIntoView();
    }
    _lastKeyboardInset = keyboardInset;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        decoration: BoxDecoration(
          color: AppColors.cardColor(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Choose a Category',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(AppIcons.close, size: 20),
                      color: AppColors.textSecondary(context),
                      onPressed: _isApplyingCategory
                          ? null
                          : () {
                              _dismissComposerState();
                              Navigator.pop(context);
                            },
                    ),
                  ],
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  controller: _sheetScrollController,
                  padding: EdgeInsets.fromLTRB(20, 0, 20, keyboardScrollBuffer),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildCategoryPicker(
                        currentCategory,
                        isLockedSelfTransfer: isLockedSelfTransfer,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryPicker(
    Category? current, {
    required bool isLockedSelfTransfer,
  }) {
    final categories = _availableCategories;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_canShowAutoCategorizationOption) ...[
            _buildAutoCategorizationCheckbox(),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!isLockedSelfTransfer)
                ...categories.map((category) {
                  final isSelected =
                      current?.id != null && category.id == current!.id;
                  return _CategoryPickerChip(
                    label: category.name,
                    color: _categoryColor(category),
                    isSelected: isSelected,
                    onTap: _isApplyingCategory
                        ? null
                        : () => _setCategory(category),
                  );
                }),
              _CategoryPickerChip(
                label: 'Self',
                color: _colorFromKey('gray'),
                isSelected: isLockedSelfTransfer ||
                    current?.name.trim().toLowerCase() == 'self',
                showColorDot: false,
                onTap: isLockedSelfTransfer || _isApplyingCategory
                    ? null
                    : _setSelfCategory,
              ),
              if (!isLockedSelfTransfer)
                _CategoryPickerChip(
                  label: _showNewCategoryForm ? 'Cancel' : '+ New',
                  color: _showNewCategoryForm
                      ? AppColors.red
                      : AppColors.textSecondary(context),
                  isSelected: false,
                  isRemove: _showNewCategoryForm,
                  showColorDot: false,
                  onTap: _isApplyingCategory ? null : _toggleNewCategoryForm,
                ),
              if (!isLockedSelfTransfer && current != null)
                _CategoryPickerChip(
                  label: 'Remove',
                  color: AppColors.red,
                  isSelected: false,
                  isRemove: true,
                  showColorDot: false,
                  onTap: _isApplyingCategory ? null : _clearCategory,
                ),
            ],
          ),
          if (!isLockedSelfTransfer && _showNewCategoryForm)
            _buildNewCategoryComposer(),
        ],
      ),
    );
  }

  Widget _buildAutoCategorizationCheckbox() {
    final counterparty = _autoCategorizationCounterparty;
    if (counterparty == null) return const SizedBox.shrink();

    final isChecked = _autoCategorizeFutureTransactions;
    final activeColor = AppColors.primaryLight;
    final borderColor = isChecked ? activeColor : AppColors.borderColor(context);

    return InkWell(
      onTap: _isApplyingCategory
          ? null
          : () {
              setState(() {
                _autoCategorizeFutureTransactions =
                    !_autoCategorizeFutureTransactions;
              });
            },
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceColor(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: isChecked ? activeColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isChecked ? activeColor : AppColors.borderColor(context),
                  width: 1.4,
                ),
              ),
              child: isChecked
                  ? const Icon(
                      Icons.check,
                      size: 14,
                      color: Colors.white,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Auto-categorize future transactions',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    counterparty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewCategoryComposer() {
    final selectedColor = _colorFromKey(_draftColorKey);
    final flow = _isCredit ? 'income' : 'expense';
    final draftName = _newCategoryController.text.trim();
    final isDuplicateName = draftName.isNotEmpty &&
        _categoryExistsForFlow(name: draftName, flow: flow);
    final canSubmit = draftName.isNotEmpty && !isDuplicateName;
    final textFieldBorderColor =
        isDuplicateName ? AppColors.red : AppColors.borderColor(context);
    final focusedBorderColor =
        isDuplicateName ? AppColors.red : AppColors.primaryLight;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newCategoryController,
                  focusNode: _newCategoryFocus,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _createNewCategoryInline(),
                  onTapOutside: (_) => _newCategoryFocus.unfocus(),
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Category name',
                    hintStyle:
                        TextStyle(color: AppColors.textTertiary(context)),
                    filled: true,
                    fillColor: AppColors.surfaceColor(context),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: textFieldBorderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: textFieldBorderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: focusedBorderColor,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _toggleColorChoices,
                child: Container(
                  height: 40,
                  width: 52,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceColor(context),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderColor(context)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: selectedColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Icon(
                        _showColorChoices
                            ? AppIcons.keyboard_arrow_up
                            : AppIcons.keyboard_arrow_down,
                        size: 16,
                        color: AppColors.textSecondary(context),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: ElevatedButton(
                  onPressed: canSubmit ? _createNewCategoryInline : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryDark,
                    foregroundColor: AppColors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Add',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
          if (_showColorChoices) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 30,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _kCategoryColorOptions.map((option) {
                    final selected = option.key == _draftColorKey;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _draftColorKey = option.key;
                            _showColorChoices = false;
                          });
                        },
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: option.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? AppColors.textPrimary(context)
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(growable: false),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _categoryColor(Category category) {
    final explicitKey = _normalizeColorKey(category.colorKey) ??
        _extractColorKey(category.iconKey);
    if (explicitKey != null) {
      return _colorFromKey(explicitKey);
    }
    return _kCategoryColorOptions[_fallbackColorIndex(category)].color;
  }

  String? _normalizeColorKey(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class _CategoryColorOption {
  final String key;
  final Color color;

  const _CategoryColorOption({
    required this.key,
    required this.color,
  });
}

const List<_CategoryColorOption> _kCategoryColorOptions = [
  _CategoryColorOption(key: 'blue', color: AppColors.blue),
  _CategoryColorOption(key: 'emerald', color: AppColors.incomeSuccess),
  _CategoryColorOption(key: 'amber', color: AppColors.amber),
  _CategoryColorOption(key: 'red', color: AppColors.red),
  _CategoryColorOption(key: 'rose', color: Color(0xFFFB7185)),
  _CategoryColorOption(key: 'magenta', color: Color(0xFFD946EF)),
  _CategoryColorOption(key: 'violet', color: Color(0xFF8B5CF6)),
  _CategoryColorOption(key: 'indigo', color: Color(0xFF6366F1)),
  _CategoryColorOption(key: 'teal', color: Color(0xFF14B8A6)),
  _CategoryColorOption(key: 'mint', color: Color(0xFF34D399)),
  _CategoryColorOption(key: 'orange', color: Color(0xFFF97316)),
  _CategoryColorOption(key: 'tangerine', color: Color(0xFFFF8C42)),
  _CategoryColorOption(key: 'yellow', color: Color(0xFFEAB308)),
  _CategoryColorOption(key: 'cyan', color: Color(0xFF06B6D4)),
  _CategoryColorOption(key: 'sky', color: Color(0xFF0EA5E9)),
  _CategoryColorOption(key: 'lime', color: Color(0xFF84CC16)),
  _CategoryColorOption(key: 'pink', color: Color(0xFFEC4899)),
  _CategoryColorOption(key: 'brown', color: Color(0xFFA16207)),
  _CategoryColorOption(key: 'gray', color: Color(0xFF6B7280)),
];

class _CategoryPickerChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSelected;
  final bool isRemove;
  final bool showColorDot;
  final VoidCallback? onTap;

  const _CategoryPickerChip({
    required this.label,
    required this.color,
    required this.isSelected,
    this.isRemove = false,
    this.showColorDot = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor =
        isSelected ? color.withValues(alpha: 0.15) : Colors.transparent;
    final borderColor = isSelected ? color : AppColors.borderColor(context);
    final isEnabled = onTap != null;
    final textColor = !isEnabled
        ? AppColors.textTertiary(context)
        : (isRemove ? AppColors.red : AppColors.textPrimary(context));

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showColorDot) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isEnabled ? color : color.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
