#include <QTextEdit>
extern "C" {
  QTextEdit::ExtraSelection* QTextEditExtraSelection_createDefault() {
    return new (std::nothrow) QTextEdit::ExtraSelection();
  }
}
