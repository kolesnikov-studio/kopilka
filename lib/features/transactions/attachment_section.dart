import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/attachments_repository.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/transactions/attachments_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';
import 'package:path/path.dart' as p;

/// Секция «Вложение» формы операции (M5-шаг 6в, D-63): после сохранения
/// живой операции файл можно прикрепить, заменить (правило «один живой
/// файл на операцию» — замена, не отказ) или удалить (с подтверждением).
///
/// Три состояния: пустое (кнопка «Прикрепить»), с вложением (карточка:
/// имя файла, размер, тип, кнопки «Открыть»/«Удалить») и BUSY — признак
/// незавершённой операции с файлом. Отсутствие файла на диске
/// (восстановленный бэкап, D-64) — вложение видно с текстом «файл
/// отсутствует», без падения (D-63/64: метаданные без файла — норма).
class AttachmentSection extends ConsumerStatefulWidget {
  const AttachmentSection({required this.transactionId, super.key});

  /// Живая операция-владелец вложения.
  final String transactionId;

  @override
  ConsumerState<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends ConsumerState<AttachmentSection> {
  bool _busy = false;

  AttachmentsController get _controller =>
      ref.read(attachmentsControllerProvider.notifier);

  /// Выбор файла → подтверждение → запись. Повторный выбор при живом
  /// вложении — замена (правило DAO «один живой файл на операцию», D-63):
  /// пользователь подтверждает это явным текстом диалога.
  Future<void> _pickAndConfirm() async {
    setState(() => _busy = true);
    final AttachmentPickOutcome picked = await _controller.pickFile();
    if (!mounted) {
      return;
    }
    switch (picked) {
      case AttachmentPickCancelled():
        setState(() => _busy = false);
      case AttachPickTooLarge(:final maxFileSizeBytes):
        setState(() => _busy = false);
        await showSnack(
          context,
          AppLocalizations.of(context).attachmentTooLarge(
            formatAttachmentSize(maxFileSizeBytes, locale: _locale()),
          ),
        );
      case AttachmentPickRejected(:final failure):
        setState(() => _busy = false);
        // Mime вне белого списка объясняется текстом именно о типе файла;
        // остальные отказы выбора (не читается) — общим текстом вида.
        if (failure == DataFailure.invalidInput) {
          await showSnack(
            context,
            AppLocalizations.of(context).attachmentMimeTypeUnsupported,
          );
        } else {
          await showDataFailureSnack(context, failure);
        }
      case AttachmentPickLoaded(:final fileName, :final bytes):
        // Диалог подтверждения строится без await до показа: в тестовой
        // зоне (fake_async) любой реальный await до showDialog не даст
        // кадру построиться.
        //
        // S2 (D-70/D-71): факт вложения для текста подтверждения берём
        // на момент показа диалога, а не из состояния провайдера в момент
        // тапа: FutureProvider.autoDispose может быть ещё не загружен на
        // первом кадре секции (переход в режим вложения) — тогда `.value`
        // до показа давал null и подтверждение замены ложно показывало
        // «Прикрепить». Билдер выполняется синхронно внутри showDialog
        // (await до показа нет — требование §7), и к этому моменту кадр
        // секции построен: виден либо чип «Прикрепить», либо карточка.
        // Читаем `.value` так же, как build секции. Исходы контроллера и
        // контракт секции не меняются.
        final bool? result = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            final bool replace = ref
                .read(transactionAttachmentProvider(widget.transactionId))
                .value !=
            null;
            return AlertDialog(
              title: Text(
                replace
                    ? AppLocalizations.of(context).attachmentReplaceTitle
                    : AppLocalizations.of(context).attachmentPickTitle,
              ),
              content: Text(
                '$fileName · '
                '${formatAttachmentSize(bytes.length, locale: _locale())}\n\n'
                '${replace
                    ? AppLocalizations.of(context).attachmentReplaceBody
                    : AppLocalizations.of(context).attachmentPickBody}',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(AppLocalizations.of(context).cancelAction),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(
                    replace
                        ? AppLocalizations.of(context).attachmentReplaceAction
                        : AppLocalizations.of(context).attachmentPickAction,
                  ),
                ),
              ],
            );
          },
        );
        if (!mounted) {
          return;
        }
        if (!(result ?? false)) {
          setState(() => _busy = false);
          return;
        }
        await _attach(picked);
    }
  }


  Future<void> _attach(AttachmentPickLoaded picked) async {
    final AttachOutcome outcome = await _controller.attachSelected(
      transactionId: widget.transactionId,
      bytes: picked.bytes,
      mimeType: picked.mimeType,
    );
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    ref.invalidate(transactionAttachmentProvider(widget.transactionId));
    switch (outcome) {
      case AttachSucceeded():
        await showSnack(context, AppLocalizations.of(context).attachmentSaved);
      case AttachFailed(:final failure):
        await showDataFailureSnack(context, failure);
    }
  }

  /// Удаление — с подтверждением (бриф): убирается и файл с диска.
  Future<void> _confirmDelete(Attachment attachment) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.attachmentDeleteTitle,
      body: l10n.attachmentDeleteBody,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final DeleteOutcome outcome = await _controller.delete(attachment.id);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    ref.invalidate(transactionAttachmentProvider(widget.transactionId));
    switch (outcome) {
      case DeleteSucceeded():
        break;
      case DeleteFailed(:final failure):
        await showDataFailureSnack(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AttachmentViewData? view = ref
        .watch(transactionAttachmentProvider(widget.transactionId))
        .value;

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.attachmentSectionTitle),
          const SizedBox(height: 4),
          if (view == null)
            OutlinedButton.icon(
              // Прикрепление доступно только живой операции: у новой ещё
              // нет id — сначала «Сохранить», секция появится после.
              onPressed: _busy ? null : _pickAndConfirm,
              icon: const Icon(Icons.attach_file),
              label: Text(l10n.attachmentPickAction),
            )
          else
            _AttachmentCard(
              view: view,
              busy: _busy,
              locale: _locale(),
              onOpen: () => _openAttachment(
                context,
                ref,
                view.attachment,
              ),
              // Замена = повторный выбор файла (правило «один живой файл
              // на операцию», D-63): тот же флоу пикера, но подтверждение
              // показывает текст замены (текущее вложение будет удалено).
              onReplace: _pickAndConfirm,
              onDelete: () => _confirmDelete(view.attachment),
            ),
        ],
      ),
    );
  }

  String _locale() => Localizations.localeOf(context).toString();
}

/// Карточка вложения: имя файла, размер, тип и кнопки «Открыть»/«Удалить».
/// Файла нет на диске (восстановленный бэкап, D-64) — вложение видно
/// с пометкой, открытие даёт отказ без падения.
class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.view,
    required this.busy,
    required this.locale,
    required this.onOpen,
    required this.onReplace,
    required this.onDelete,
  });

  final AttachmentViewData view;
  final bool busy;
  final String locale;
  final VoidCallback onOpen;
  final VoidCallback onReplace;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Attachment attachment = view.attachment;
    final bool isPdf = attachment.mimeType == 'application/pdf';
    final Color subtitleColor = Theme.of(context).colorScheme.onSurfaceVariant;

    return InputDecorator(
      decoration: const InputDecoration(border: OutlineInputBorder()),
      child: Row(
        children: <Widget>[
          Icon(isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  p.basename(attachment.filePath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${formatAttachmentSize(attachment.fileSize, locale: locale)}'
                  ' · ${attachment.mimeType}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: subtitleColor),
                ),
                if (!view.fileExists)
                  Text(
                    l10n.attachmentFileMissing,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.attachmentOpenAction,
            onPressed: busy ? null : onOpen,
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: l10n.attachmentReplaceAction,
            onPressed: busy ? null : onReplace,
            icon: const Icon(Icons.published_with_changes),
          ),
          IconButton(
            tooltip: l10n.deleteAction,
            onPressed: busy ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

/// Открытие вложения (бриф п. 3): фото — полноэкранный просмотр средствами
/// Flutter (InteractiveViewer, без новых пакетов), PDF — вне MVP (фаза 2,
/// D-63): диалог с метаданными и честным «просмотр недоступен», без
/// падения. Отсутствие файла — снекбар с локализованным отказом; ни один
/// из исходов не роняет операцию.
Future<void> _openAttachment(
  BuildContext context,
  WidgetRef ref,
  Attachment attachment,
) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final AttachmentsService service = ref.read(attachmentsServiceProvider);
  final String path =
      p.join(service.directory.path, attachment.filePath);
  // Проверка файла — через шов I/O (в тестах фейк без файловой системы).
  if (!await ref.read(attachmentsIoProvider).exists(path)) {
    if (!context.mounted) {
      return;
    }
    await showSnack(context, l10n.attachmentFileMissing);
    return;
  }
  if (attachment.mimeType == 'application/pdf') {
    if (!context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(l10n.attachmentOpenAction),
        content: Text(
          '${p.basename(attachment.filePath)}\n\n'
          '${formatAttachmentSize(attachment.fileSize, locale: Localizations.localeOf(context).toString())}\n\n'
          '${l10n.attachmentPdfUnsupported}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) {
    return;
  }
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (BuildContext viewerContext) => _ImageViewerScreen(path: path),
    ),
  );
}

/// Полноэкранный просмотр фото средствами Flutter (InteractiveViewer:
/// зум и пан жестами; системный просмотрщик потребовал бы новый канал —
/// новых зависимостей по брифу ноль).
class _ImageViewerScreen extends StatelessWidget {
  const _ImageViewerScreen({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.attachmentFileMissing,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
