import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_form_header.dart';
import '../../../../shared/widgets/character_counter.dart';
import '../../domain/media_feature_flag.dart';

/// Opens the image description (alt text) editor: a full-screen route below
/// [AppBreakpoints.mobile] wide, a centred dialog above (the same split as
/// the Schedule dialog). Returns the text to keep on Save, or null when the
/// editor is cancelled or dismissed (nothing changes then). The caller writes
/// the result into its attachment state.
Future<String?> showAltTextEditor(
  BuildContext context, {
  required String initial,
  Uint8List? preview,
}) {
  final view = AltTextEditorView(initial: initial, preview: preview);
  if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
    return Navigator.of(context).push(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(body: SafeArea(child: view)),
      ),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: view,
      ),
    ),
  );
}

/// The content of the editor: Cancel, the "Description" title and a Save pill
/// ([AppFormHeader]); the image preview; the description field with a
/// [CharacterCounter] against [kMaxAltTextLength] counted in code points (the
/// unit `AttachmentsCubit.setAltText` clips to). Over the limit the counter
/// turns red and Save is off; an empty description is valid (it clears the
/// text). Scrolls, so it fits any text scale.
class AltTextEditorView extends StatefulWidget {
  const AltTextEditorView({super.key, required this.initial, this.preview});

  final String initial;

  /// The thumbnail of the image being described (null: no preview shown).
  final Uint8List? preview;

  /// Tallest the preview grows (dp).
  static const double previewMaxHeight = 200;

  @override
  State<AltTextEditorView> createState() => _AltTextEditorViewState();
}

class _AltTextEditorViewState extends State<AltTextEditorView> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final remaining = kMaxAltTextLength - value.text.runes.length;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormHeader(
              title: 'Description',
              onCancel: () => Navigator.of(context).pop(),
              actionLabel: 'Save',
              onAction: remaining < 0
                  ? null
                  : () => Navigator.of(context).pop(_controller.text),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (preview != null) ...[
                      Semantics(
                        image: true,
                        label: 'Photo being described',
                        excludeSemantics: true,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: AltTextEditorView.previewMaxHeight,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            child: Image.memory(
                              preview,
                              fit: BoxFit.contain,
                              cacheWidth:
                                  (AltTextEditorView.previewMaxHeight *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .ceil(),
                              errorBuilder: (_, _, _) => Icon(
                                Icons.broken_image_outlined,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    TextField(
                      controller: _controller,
                      autofocus: true,
                      minLines: 3,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: 'Description',
                        hintText:
                            'Describe the photo for people who cannot see it',
                        alignLabelWithHint: true,
                        counter: CharacterCounter(remaining: remaining),
                        errorText: remaining < 0
                            ? 'At most $kMaxAltTextLength characters.'
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
