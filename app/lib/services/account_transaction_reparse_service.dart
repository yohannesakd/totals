import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:totals/constants/cash_constants.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/services/bank_config_service.dart';
import 'package:totals/services/sms_config_service.dart';
import 'package:totals/sms_handler/telephony.dart';
import 'package:totals/utils/pattern_parser.dart';

class AccountTransactionReparseResult {
  final bool unsupported;
  final bool permissionDenied;
  final String? errorMessage;
  final int scannedMessages;
  final int parsedMessages;
  final int matchedTransactions;
  final int updatedTransactions;
  final int addedReceiptLinks;

  const AccountTransactionReparseResult({
    this.unsupported = false,
    this.permissionDenied = false,
    this.errorMessage,
    this.scannedMessages = 0,
    this.parsedMessages = 0,
    this.matchedTransactions = 0,
    this.updatedTransactions = 0,
    this.addedReceiptLinks = 0,
  });
}

class AccountTransactionReparseService {
  final Telephony _telephony = Telephony.instance;
  final BankConfigService _bankConfigService = BankConfigService();
  final SmsConfigService _smsConfigService = SmsConfigService();
  final TransactionRepository _transactionRepo = TransactionRepository();
  List<Bank>? _cachedBanks;

  Future<AccountTransactionReparseResult> reparseAccountTransactions({
    required int bankId,
    required String accountNumber,
    required List<Transaction> transactions,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const AccountTransactionReparseResult(unsupported: true);
    }
    if (bankId == CashConstants.bankId) {
      return const AccountTransactionReparseResult(
        unsupported: true,
        errorMessage: 'Cash transactions do not have source SMS receipts.',
      );
    }
    if (transactions.isEmpty) {
      return const AccountTransactionReparseResult();
    }

    var permissionStatus = await Permission.sms.status;
    if (!permissionStatus.isGranted) {
      permissionStatus = await Permission.sms.request();
    }
    if (!permissionStatus.isGranted) {
      return const AccountTransactionReparseResult(permissionDenied: true);
    }

    _cachedBanks ??= await _bankConfigService.getBanks();
    final bank = _cachedBanks!.firstWhere(
      (item) => item.id == bankId,
      orElse: () => throw StateError('Bank $bankId not found'),
    );

    final patterns = await _smsConfigService.getPatterns();
    final relevantPatterns =
        patterns.where((pattern) => pattern.bankId == bankId);
    if (relevantPatterns.isEmpty) {
      return const AccountTransactionReparseResult(
        errorMessage: 'No parsing patterns are configured for this bank.',
      );
    }

    final existingByReference = <String, Transaction>{
      for (final transaction in transactions)
        if (transaction.reference.trim().isNotEmpty)
          transaction.reference: transaction,
    };
    if (existingByReference.isEmpty) {
      return const AccountTransactionReparseResult();
    }

    final messages = await _loadBankMessages(bank);
    int parsedMessages = 0;
    final matchedReferences = <String>{};
    final updatedReferences = <String>{};
    final linkAddedReferences = <String>{};

    for (final message in messages) {
      final body = message.body;
      final address = message.address;
      if (body == null || address == null) continue;

      final messageDate = message.date == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(message.date!);
      final details = await PatternParser.extractTransactionDetails(
        _smsConfigService.cleanSmsText(body),
        address,
        messageDate,
        relevantPatterns.toList(growable: false),
      );
      if (details == null) continue;
      parsedMessages++;

      final reference = details['reference']?.toString().trim();
      if (reference == null || reference.isEmpty) continue;

      final existing = existingByReference[reference];
      if (existing == null) continue;
      if (!_matchesAccount(bank, accountNumber, existing, details)) continue;

      matchedReferences.add(reference);
      final reparsed = Transaction.fromJson(details);
      final updated = _mergeParsedFields(existing, reparsed);
      if (updated == null) continue;

      await _transactionRepo.saveTransaction(
        updated,
        skipAutoCategorization: true,
      );
      existingByReference[reference] = updated;
      updatedReferences.add(reference);
      if (!_hasText(existing.transactionLink) &&
          _hasText(updated.transactionLink)) {
        linkAddedReferences.add(reference);
      }
    }

    return AccountTransactionReparseResult(
      scannedMessages: messages.length,
      parsedMessages: parsedMessages,
      matchedTransactions: matchedReferences.length,
      updatedTransactions: updatedReferences.length,
      addedReceiptLinks: linkAddedReferences.length,
    );
  }

  Future<List<SmsMessage>> _loadBankMessages(Bank bank) async {
    final bankCodes =
        bank.codes.where((code) => code.trim().isNotEmpty).toList();
    final allMessages = <SmsMessage>[];

    if (bankCodes.isEmpty) {
      allMessages.addAll(
        await _telephony.getInboxSms(
          columns: const [
            SmsColumn.ADDRESS,
            SmsColumn.BODY,
            SmsColumn.DATE,
          ],
          sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
        ),
      );
    } else {
      for (final code in bankCodes.toSet()) {
        final batch = await _telephony.getInboxSms(
          columns: const [
            SmsColumn.ADDRESS,
            SmsColumn.BODY,
            SmsColumn.DATE,
          ],
          sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
          filter: SmsFilter.where(SmsColumn.ADDRESS).like('%$code%'),
        );
        allMessages.addAll(batch);
      }
    }

    final byKey = <String, SmsMessage>{};
    for (final message in allMessages) {
      final address = message.address;
      final body = message.body;
      if (address == null || body == null) continue;
      if (!_matchesBankAddress(bank, address)) continue;
      final key = '${message.date}_${address.trim()}_${body.trim()}';
      byKey.putIfAbsent(key, () => message);
    }

    final unique = byKey.values.toList(growable: false);
    unique.sort((a, b) => (b.date ?? 0).compareTo(a.date ?? 0));
    return unique;
  }

  bool _matchesBankAddress(Bank bank, String address) {
    final normalizedAddress = _normalizeSenderToken(address);
    if (normalizedAddress.isEmpty) return false;
    for (final code in bank.codes) {
      final normalizedCode = _normalizeSenderToken(code);
      if (normalizedCode.isEmpty) continue;
      if (normalizedAddress.contains(normalizedCode)) return true;
    }
    return false;
  }

  String _normalizeSenderToken(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _matchesAccount(
    Bank bank,
    String accountNumber,
    Transaction existing,
    Map<String, dynamic> details,
  ) {
    if (existing.accountNumber?.trim().isNotEmpty == true) {
      return _accountSuffix(existing.accountNumber!, bank) ==
          _accountSuffix(accountNumber, bank);
    }

    final parsedAccount = details['accountNumber']?.toString().trim();
    if (parsedAccount == null || parsedAccount.isEmpty) {
      return true;
    }
    return _accountSuffix(parsedAccount, bank) ==
        _accountSuffix(accountNumber, bank);
  }

  String _accountSuffix(String accountNumber, Bank bank) {
    final trimmed = accountNumber.trim();
    final maskLength = bank.maskPattern;
    if (maskLength == null || maskLength <= 0 || trimmed.length <= maskLength) {
      return trimmed;
    }
    return trimmed.substring(trimmed.length - maskLength);
  }

  Transaction? _mergeParsedFields(Transaction existing, Transaction reparsed) {
    final updated = Transaction(
      amount: existing.amount,
      reference: existing.reference,
      creditor: _pickText(existing.creditor, reparsed.creditor),
      receiver: _pickText(existing.receiver, reparsed.receiver),
      note: existing.note,
      time: _pickText(existing.time, reparsed.time),
      status: _pickText(existing.status, reparsed.status),
      currentBalance:
          _pickText(existing.currentBalance, reparsed.currentBalance),
      bankId: existing.bankId ?? reparsed.bankId,
      type: _pickText(existing.type, reparsed.type),
      transactionLink: _pickTransactionLink(
          existing.transactionLink, reparsed.transactionLink),
      accountNumber: _pickText(existing.accountNumber, reparsed.accountNumber),
      categoryId: existing.categoryId,
      profileId: existing.profileId,
      serviceCharge:
          _pickAmount(existing.serviceCharge, reparsed.serviceCharge),
      vat: _pickAmount(existing.vat, reparsed.vat),
    );

    if (_isSameTransaction(existing, updated)) {
      return null;
    }
    return updated;
  }

  bool _isSameTransaction(Transaction a, Transaction b) {
    return a.amount == b.amount &&
        a.reference == b.reference &&
        a.creditor == b.creditor &&
        a.receiver == b.receiver &&
        a.note == b.note &&
        a.time == b.time &&
        a.status == b.status &&
        a.currentBalance == b.currentBalance &&
        a.bankId == b.bankId &&
        a.type == b.type &&
        a.transactionLink == b.transactionLink &&
        a.accountNumber == b.accountNumber &&
        a.categoryId == b.categoryId &&
        a.profileId == b.profileId &&
        a.serviceCharge == b.serviceCharge &&
        a.vat == b.vat;
  }

  String? _pickText(String? existing, String? reparsed) {
    final normalizedExisting = _normalizeText(existing);
    if (normalizedExisting != null) return existing;
    return _normalizeText(reparsed);
  }

  String? _pickTransactionLink(String? existing, String? reparsed) {
    final normalizedExisting = _normalizeText(existing);
    if (normalizedExisting != null) return normalizedExisting;
    return _normalizeText(reparsed);
  }

  double? _pickAmount(double? existing, double? reparsed) {
    if (_hasMeaningfulAmount(existing)) return existing;
    if (_hasMeaningfulAmount(reparsed)) return reparsed;
    return existing;
  }

  bool _hasMeaningfulAmount(double? value) {
    return value != null && value != 0;
  }

  String? _normalizeText(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  bool _hasText(String? value) => _normalizeText(value) != null;
}
