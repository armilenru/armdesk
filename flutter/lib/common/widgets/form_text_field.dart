import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';

/// One text field of a dialog form, labeled inside the field.
///
/// `DialogTextField` in dialog.dart is the same idea, but it cannot be disabled
/// and always takes the focus; the proxy dialog needs both under control.
///
/// Dialog forms used to stand each label in a column `minWidth: 140` wide to
/// the left of its field. A minimum is not a width: a label longer than that,
/// as most Russian ones are, pushed its own field to the right, so the fields
/// of one dialog started in different places, and a character counter under a
/// field dragged that field's label off its center line. With the label inside
/// the field every field takes the dialog's full width in any language.
class FormTextField extends StatefulWidget {
  const FormTextField({
    super.key,
    required this.label,
    required this.controller,
    this.errorText,
    this.errorMaxLines,
    this.hintText,
    this.tip,
    this.isRequired = false,
    this.inputFormatters,
    this.minLines,
    this.maxLines = 1,
    this.enabled = true,
    this.autofocus = false,
    this.isPassword = false,
    this.maxLength,
    this.desktop,
  });

  final String label;
  final TextEditingController controller;
  final String? errorText;
  final int? errorMaxLines;
  final String? hintText;

  /// Marks the label with a red asterisk.
  final bool isRequired;
  final List<TextInputFormatter>? inputFormatters;
  final int? minLines;
  final int? maxLines;

  /// Shown under the field on a phone and behind a help icon on the desktop.
  final String? tip;
  final bool enabled;
  final bool autofocus;
  final bool isPassword;
  final int? maxLength;

  /// The desktop look, [isDesktop] unless a test says otherwise.
  final bool? desktop;

  @override
  State<FormTextField> createState() => _FormTextFieldState();
}

class _FormTextFieldState extends State<FormTextField> {
  late bool _hidden = widget.isPassword;

  @override
  Widget build(BuildContext context) {
    final desktop = widget.desktop ?? isDesktop;
    final tip = widget.tip;
    Widget? suffix;
    if (widget.isPassword) {
      suffix = IconButton(
          onPressed: () => setState(() => _hidden = !_hidden),
          icon: Icon(_hidden ? Icons.visibility_off : Icons.visibility));
    } else if (desktop && tip != null) {
      suffix = Tooltip(
        waitDuration: Duration.zero,
        message: tip,
        child: Icon(Icons.help_outline_outlined,
            size: 18,
            color: Theme.of(context)
                .textTheme
                .titleLarge
                ?.color
                ?.withOpacity(0.5)),
      );
    }
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: _hidden,
      maxLength: widget.maxLength,
      inputFormatters: widget.inputFormatters,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: widget.isRequired ? null : widget.label,
        label: widget.isRequired
            ? Text.rich(TextSpan(text: widget.label, children: const [
                TextSpan(text: ' *', style: TextStyle(color: Colors.red))
              ]))
            : null,
        hintText: widget.hintText,
        errorText: widget.errorText,
        errorMaxLines: widget.errorMaxLines,
        helperText: desktop ? null : tip,
        helperMaxLines: desktop ? null : 3,
        suffixIcon: suffix,
        border: MyTheme.insideLabelBorder,
        contentPadding: MyTheme.insideLabelPadding,
      ),
    ).workaroundFreezeLinuxMint();
  }
}
