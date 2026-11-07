#import "CustomPhraseEditor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *phraseString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]?:@"";
}
static NSString *trimASCII(NSString *value) {
    NSUInteger start=0,end=value.length;
    while(start<end && [value characterAtIndex:start]<=32) ++start;
    while(end>start && [value characterAtIndex:end-1]<=32) --end;
    return [value substringWithRange:NSMakeRange(start,end-start)];
}
static NSString *phraseKey(NSString *value) {
    NSString *key=trimASCII(value).lowercaseString;
    if(!key.length || key.length>32) return nil;
    for(NSUInteger i=0;i<key.length;++i) {
        unichar c=[key characterAtIndex:i]; if(c<'a' || c>'z') return nil;
    }
    return key;
}
static BOOL phraseTextValid(NSString *text) {
    if(!trimASCII(text).length || text.length>4096 || ![text dataUsingEncoding:NSUTF8StringEncoding]) return NO;
    for(NSUInteger i=0;i<text.length;++i) {
        unichar c=[text characterAtIndex:i]; if(c<32 && c!=9 && c!=10 && c!=13) return NO;
    }
    return YES;
}
NSString *CassotisCustomPhrasePreview(NSString *text) {
    NSUInteger count=MIN(text.length,120);
    if(count<text.length && CFStringIsSurrogateHighCharacter([text characterAtIndex:count-1])) --count;
    NSString *value=[text substringToIndex:count];
    for(NSString *control in @[@"\t",@"\r",@"\n"]) value=[value stringByReplacingOccurrencesOfString:control withString:@" "];
    return count<text.length?[value stringByAppendingString:@"..."]:value;
}
BOOL CassotisParseCustomPhrases(NSData *data,std::vector<cassotis::CustomPhrase> &phrases,NSString **error) {
    phrases.clear();
    if(data.length>16*1024*1024) { if(error) *error=@"文件不能超过 16 MB。"; return NO; }
    id rows=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![rows isKindOfClass:NSArray.class] || [rows count]>1024) {
        if(error) *error=@"请选择自定义短语 JSON 文件，最多 1024 条。"; return NO;
    }
    std::vector<cassotis::CustomPhrase> parsed;
    for(id row in rows) {
        if(![row isKindOfClass:NSArray.class] || [row count]!=2 ||
            ![row[0] isKindOfClass:NSString.class] || ![row[1] isKindOfClass:NSString.class] ||
            !phraseKey(row[0]) || !phraseTextValid(row[1])) {
            if(error) *error=@"每条短语须包含 1–32 个英文字母的缩写和非空内容（最多 4096 字符）。";
            return NO;
        }
        parsed.push_back({phraseKey(row[0]).UTF8String,[row[1] UTF8String]});
    }
    phrases=std::move(parsed); return YES;
}
NSData *CassotisCustomPhraseJSON(const std::vector<cassotis::CustomPhrase> &phrases) {
    NSMutableArray *rows=[NSMutableArray array];
    for(const auto &phrase:phrases) [rows addObject:@[phraseString(phrase.shortcut),phraseString(phrase.text)]];
    return [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];
}

// The input method has no Edit menu. These fields still support the usual
// Command editing shortcuts, including undo, without converting literal text.
static BOOL phraseEditingKey(NSTextView *editor,NSEvent *event) {
    NSUInteger flags=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;
    flags&=~(NSEventModifierFlagCapsLock|NSEventModifierFlagNumericPad|NSEventModifierFlagFunction);
    if(flags!=NSEventModifierFlagCommand && flags!=(NSEventModifierFlagCommand|NSEventModifierFlagShift)) return NO;
    NSString *key=event.charactersIgnoringModifiers.lowercaseString;
    if([key isEqual:@"z"]) {
        if(flags&NSEventModifierFlagShift) { if(editor.undoManager.canRedo) [editor.undoManager redo]; }
        else if(editor.undoManager.canUndo) [editor.undoManager undo];
        return YES;
    }
    if(flags!=NSEventModifierFlagCommand) return NO;
    if([key isEqual:@"a"]) [editor selectAll:nil];
    else if([key isEqual:@"c"]) [editor copy:nil];
    else if([key isEqual:@"x"]) [editor cut:nil];
    else if([key isEqual:@"v"]) [editor pasteAsPlainText:nil];
    else return NO;
    return YES;
}
@interface CassotisPhraseTextView : NSTextView
@end
@implementation CassotisPhraseTextView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return phraseEditingKey(self,event) || [super performKeyEquivalent:event];
}
@end
@interface CassotisPhraseKeyField : NSTextField
@end
@implementation CassotisPhraseKeyField
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSTextView *editor=(NSTextView *)self.currentEditor;
    return ([editor isKindOfClass:NSTextView.class] && phraseEditingKey(editor,event)) || [super performKeyEquivalent:event];
}
@end

@interface CassotisCustomPhraseEditor () <NSTableViewDelegate,NSTableViewDataSource,NSTextFieldDelegate,NSTextViewDelegate>
@end
@implementation CassotisCustomPhraseEditor {
    NSTableView *_table;
    NSTextField *_key, *_notice, *_listTitle;
    NSTextView *_text;
    NSButton *_submit, *_cancel;
    NSArray<NSButton *> *_actions;
    std::vector<cassotis::CustomPhrase> _saved;
    NSInteger _editingRow;
    BOOL _loading, _dirty;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame]; if(!self) return nil;
    self.accessibilityIdentifier=@"custom-phrase-editor";
    _editingRow=-1;
    _table=[[NSTableView alloc] init]; _table.delegate=self; _table.dataSource=self;
    _table.rowHeight=28; _table.usesAlternatingRowBackgroundColors=YES;
    _table.accessibilityIdentifier=@"custom-phrase-list";
    for(NSString *title in @[@"缩写",@"短语内容"]) {
        NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:title]; column.title=title;
        column.width=[title isEqual:@"缩写"]?100:320; column.minWidth=70;
        [_table addTableColumn:column];
    }
    NSScrollView *list=[[NSScrollView alloc] init]; list.documentView=_table;
    list.hasVerticalScroller=YES; list.borderType=NSBezelBorder;
    [list.heightAnchor constraintEqualToConstant:168].active=YES;
    NSMutableArray *buttons=[NSMutableArray array];
    NSArray *titles=@[@"删除",@"上移",@"下移",@"导入…",@"导出…"];
    for(NSUInteger i=0;i<titles.count;++i) {
        NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(action:)];
        button.tag=i+1; button.accessibilityIdentifier=[NSString stringWithFormat:@"custom-phrase-action-%lu",(unsigned long)i+1];
        [buttons addObject:button];
    }
    _actions=buttons;
    NSStackView *actions=[NSStackView stackViewWithViews:buttons]; actions.spacing=5;
    _key=[[CassotisPhraseKeyField alloc] init]; _key.placeholderString=@"例如 cx，1–32 个英文字母";
    _key.delegate=self; _key.accessibilityIdentifier=@"custom-phrase-shortcut"; _key.accessibilityLabel=@"缩写";
    _text=[[CassotisPhraseTextView alloc] initWithFrame:NSMakeRect(0,0,400,96)];
    _text.delegate=self; _text.richText=NO; _text.importsGraphics=NO; _text.allowsUndo=YES;
    _text.automaticQuoteSubstitutionEnabled=NO; _text.automaticDashSubstitutionEnabled=NO;
    _text.automaticTextReplacementEnabled=NO; _text.automaticSpellingCorrectionEnabled=NO;
    _text.font=[NSFont systemFontOfSize:13]; _text.textContainerInset=NSMakeSize(6,6);
    _text.accessibilityIdentifier=@"custom-phrase-text"; _text.accessibilityLabel=@"短语内容";
    _text.verticallyResizable=YES; _text.horizontallyResizable=NO; _text.autoresizingMask=NSViewWidthSizable;
    _text.textContainer.widthTracksTextView=YES;
    NSScrollView *textScroll=[[NSScrollView alloc] init]; textScroll.documentView=_text;
    textScroll.hasVerticalScroller=YES; textScroll.borderType=NSBezelBorder;
    [textScroll.heightAnchor constraintEqualToConstant:96].active=YES;
    _notice=[NSTextField wrappingLabelWithString:@""]; _notice.font=[NSFont systemFontOfSize:12];
    _notice.textColor=NSColor.secondaryLabelColor; _notice.accessibilityIdentifier=@"custom-phrase-notice";
    _submit=[NSButton buttonWithTitle:@"添加短语" target:self action:@selector(submit:)];
    _submit.accessibilityIdentifier=@"custom-phrase-submit"; _submit.bezelColor=NSColor.controlAccentColor;
    [_submit.widthAnchor constraintGreaterThanOrEqualToConstant:96].active=YES;
    _cancel=[NSButton buttonWithTitle:@"清空" target:self action:@selector(cancel:)];
    _cancel.accessibilityIdentifier=@"custom-phrase-cancel";
    NSStackView *editActions=[NSStackView stackViewWithViews:@[_submit,_cancel]]; editActions.spacing=8;
    NSTextField *keyLabel=[NSTextField labelWithString:@"缩写"];
    NSTextField *textLabel=[NSTextField labelWithString:@"短语内容"];
    _listTitle=[NSTextField labelWithString:@""]; _listTitle.font=[NSFont boldSystemFontOfSize:13];
    NSStackView *stack=[NSStackView stackViewWithViews:@[keyLabel,_key,textLabel,textScroll,editActions,_notice,_listTitle,list,actions]];
    stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.alignment=NSLayoutAttributeLeading; stack.spacing=8;
    [self addSubview:stack]; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
    for(NSView *view in @[list,_key,textScroll,_notice]) [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;
    [self refreshControls]; return self;
}
- (void)setEnabled:(BOOL)value { _enabled=value; [self refreshControls]; }
- (void)setPhrases:(const std::vector<cassotis::CustomPhrase> &)phrases {
    _saved=phrases; [self selectRow:-1];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return _saved.size(); }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    const auto &phrase=_saved[row];
    NSString *value=phraseString([column.identifier isEqual:@"缩写"]?phrase.shortcut:phrase.text);
    NSTextField *field=[NSTextField labelWithString:CassotisCustomPhrasePreview(value)];
    field.lineBreakMode=NSLineBreakByTruncatingTail; return field;
}
- (BOOL)selectionShouldChangeInTableView:(NSTableView *)tableView {
    (void)tableView;
    if(_loading || !_dirty) return YES;
    _notice.stringValue=_editingRow<0?@"请先点击“添加短语”提交，或点击“清空”放弃草稿。":
        @"请先点击“保存修改”提交，或点击“取消编辑”保留原内容。";
    return NO;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification { (void)notification; if(!_loading) [self showSelection]; }
- (void)showSelection {
    _loading=YES; _editingRow=_table.selectedRow;
    _key.stringValue=_editingRow<0?@"":phraseString(_saved[_editingRow].shortcut);
    _text.string=_editingRow<0?@"":phraseString(_saved[_editingRow].text); [_text.undoManager removeAllActions];
    _dirty=NO;
    _loading=NO; [self refreshControls];
}
- (void)refreshControls {
    BOOL selected=_editingRow>=0;
    _table.enabled=_enabled; _key.enabled=_enabled; _text.editable=_enabled;
    _submit.title=selected?@"保存修改":@"添加短语";
    _submit.enabled=_enabled && _dirty && (selected || _saved.size()<1024);
    _cancel.title=selected?@"取消编辑":@"清空"; _cancel.enabled=_enabled && (selected || _dirty);
    _actions[0].enabled=_enabled && selected && !_dirty;
    _actions[1].enabled=_enabled && _editingRow>0 && !_dirty;
    _actions[2].enabled=_enabled && selected && _editingRow+1<(NSInteger)_saved.size() && !_dirty;
    _actions[3].enabled=_enabled && !_dirty;
    _actions[4].enabled=_enabled && !_saved.empty();
    _listTitle.stringValue=[NSString stringWithFormat:@"已保存的短语（%lu / 1024）",(unsigned long)_saved.size()];
    if(_dirty) {
        _notice.stringValue=selected?@"修改尚未提交。点击“保存修改”后生效。":@"填写完成后，点击“添加短语”加入列表。";
    } else {
        NSMutableSet *seen=[NSMutableSet set]; NSString *duplicate=nil;
        for(const auto &phrase:_saved) {
            NSString *key=phraseString(phrase.shortcut);
            if([seen containsObject:key]) { duplicate=key; break; } [seen addObject:key];
        }
        _notice.stringValue=duplicate?[NSString stringWithFormat:@"缩写 %@ 重复，只显示列表中的第一条；可用上移、下移调整优先顺序。",duplicate]:
            (selected?@"正在编辑选中的短语。点击“取消编辑”可返回新增。":@"填写缩写和内容，点击“添加短语”后生效。");
        if(!selected && _saved.size()>=1024) _notice.stringValue=@"已达到 1024 条上限；可选择现有条目修改或删除。";
    }
}
- (void)edited {
    if(_loading) return;
    // Drafts live only in the two editors. Table rows always come from the
    // committed C++ strings, never from NSTextView's mutable text storage.
    _dirty=_editingRow<0?(_key.stringValue.length || _text.string.length):
        ![_key.stringValue isEqual:phraseString(_saved[_editingRow].shortcut)] ||
        ![_text.string isEqual:phraseString(_saved[_editingRow].text)];
    [self refreshControls];
}
- (void)controlTextDidChange:(NSNotification *)notification { (void)notification; [self edited]; }
- (void)textDidChange:(NSNotification *)notification { (void)notification; [self edited]; }
- (void)submit:(id)sender { (void)sender; [self submitDraft]; }
- (void)cancel:(id)sender { (void)sender; [self cancelDraft]; [self.window makeFirstResponder:_key]; }
- (void)cancelDraft { [self selectRow:-1]; }
- (BOOL)saveList:(const std::vector<cassotis::CustomPhrase> &)next selectingRow:(NSInteger)row {
    if(!self.savePhrases || !self.savePhrases(next)) {
        _notice.stringValue=@"保存失败，列表未改变。请稍后重试。"; return NO;
    }
    _saved=next; [self selectRow:row]; return YES;
}
- (BOOL)submitDraft {
    if(_loading || !_enabled) return NO;
    if(!_dirty) return YES;
    if(_text.hasMarkedText || ([_key.currentEditor isKindOfClass:NSTextView.class] &&
        [(NSTextView *)_key.currentEditor hasMarkedText])) {
        _notice.stringValue=@"请先完成当前文字输入，再提交短语。"; return NO;
    }
    NSString *key=phraseKey(_key.stringValue), *text=[_text.string copy];
    if(!key || !phraseTextValid(text)) {
        _notice.stringValue=@"尚未提交：缩写须为 1–32 个英文字母，内容不能为空且最多 4096 字符。"; return NO;
    }
    BOOL adding=_editingRow<0;
    if(adding && _saved.size()>=1024) { _notice.stringValue=@"已达到 1024 条上限。"; return NO; }
    auto next=_saved; cassotis::CustomPhrase phrase{key.UTF8String,text.UTF8String};
    if(adding) next.push_back(phrase); else next[_editingRow]=phrase;
    if(![self saveList:next selectingRow:_editingRow]) return NO;
    if(adding) {
        [_table scrollRowToVisible:_saved.size()-1]; [self.window makeFirstResponder:_key];
    }
    _notice.stringValue=adding?@"已添加到列表，可继续填写下一条短语。":@"修改已保存。";
    NSUInteger matches=0;
    for(const auto &saved:_saved) if(saved.shortcut==phrase.shortcut) ++matches;
    if(matches>1) _notice.stringValue=[NSString stringWithFormat:
        @"已保存。缩写 %@ 重复，输入时使用列表中的第一条，可用上移调整顺序。",key];
    return YES;
}
- (void)selectRow:(NSInteger)row {
    _loading=YES; [_table reloadData];
    if(row>=0) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    else [_table deselectAll:nil];
    _loading=NO; [self showSelection]; if(row>=0) [_table scrollRowToVisible:row];
}
- (void)action:(NSButton *)sender {
    if(!_enabled) return;
    // List actions operate only on committed phrases. Never implicitly submit
    // a draft when selecting, reordering, importing, exporting or closing.
    if(_dirty && sender.tag!=5) { [self selectionShouldChangeInTableView:_table]; return; }
    if(sender.tag==1 && _editingRow>=0) {
        NSInteger row=_editingRow; auto next=_saved; next.erase(next.begin()+row);
        [self saveList:next selectingRow:MIN(row,(NSInteger)next.size()-1)];
        return;
    }
    if((sender.tag==2 || sender.tag==3) && _editingRow>=0) {
        NSInteger row=_editingRow+(sender.tag==2?-1:1);
        if(row<0 || row>=(NSInteger)_saved.size()) return;
        auto next=_saved; std::swap(next[_editingRow],next[row]);
        [self saveList:next selectingRow:row];
    } else if(sender.tag==4) {
        NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.allowedContentTypes=@[UTTypeJSON];
        panel.message=@"导入 Windows / macOS 自定义短语 JSON，追加到现有列表。";
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
            if(result!=NSModalResponseOK) return;
            NSNumber *size=nil; [panel.URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if(!size || size.unsignedLongLongValue>16*1024*1024) { self->_notice.stringValue=@"文件不能超过 16 MB。"; return; }
            NSData *data=[NSData dataWithContentsOfURL:panel.URL options:NSDataReadingMappedIfSafe error:nil];
            std::vector<cassotis::CustomPhrase> imported; NSString *error=nil;
            if(!CassotisParseCustomPhrases(data,imported,&error)) { self->_notice.stringValue=error; return; }
            if(self->_saved.size()+imported.size()>1024) { self->_notice.stringValue=@"导入后超过 1024 条，文件未导入。"; return; }
            auto combined=self->_saved; combined.insert(combined.end(),imported.begin(),imported.end());
            [self saveList:combined selectingRow:combined.empty()?-1:(NSInteger)combined.size()-1];
        }];
    } else if(sender.tag==5) {
        NSSavePanel *panel=[NSSavePanel savePanel]; panel.allowedContentTypes=@[UTTypeJSON];
        panel.nameFieldStringValue=@"cassotis_custom_phrases.json";
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
            if(result!=NSModalResponseOK) return;
            NSError *error=nil;
            if(![CassotisCustomPhraseJSON(self->_saved) writeToURL:panel.URL options:NSDataWritingAtomic error:&error])
                self->_notice.stringValue=[@"导出失败：" stringByAppendingString:error.localizedDescription];
            else self->_notice.stringValue=@"自定义短语已导出。";
        }];
    }
}
@end
