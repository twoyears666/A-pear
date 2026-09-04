#import "PLUINodeView.h"
#import "PLThemeManager.h"

/// 无固定尺寸标记（NAN 表示按内容/权重布局）。
static CGFloat const PLUINodeAuto = NAN;

#pragma mark - 值解析（$color: / $image: / $i18n: / sf: / dimen）

static NSDictionary *PLUIMergedNode(NSDictionary *node, BOOL compact) {
    // responsive.phone 覆盖：compact 尺寸类下浅合并属性
    id override = [node[@"responsive"] isKindOfClass:NSDictionary.class]
        ? node[@"responsive"][@"phone"] : nil;
    if (!compact || ![override isKindOfClass:NSDictionary.class] || [(NSDictionary *)override count] == 0) {
        return node;
    }
    NSMutableDictionary *merged = [node mutableCopy];
    [(NSDictionary *)override enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class]) merged[key] = value;
    }];
    return merged;
}

/// 数值或 dimen 表（{_dimen={phone=,pad=,default=}}）→ 具体数值；无法解析返回 NAN。
static CGFloat PLUIResolveDimen(id value, BOOL compact) {
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dimen = [value[@"_dimen"] isKindOfClass:NSDictionary.class] ? value[@"_dimen"] : nil;
        if (dimen) {
            id picked = compact ? (dimen[@"phone"] ?: dimen[@"default"]) : (dimen[@"pad"] ?: dimen[@"default"]);
            if ([picked isKindOfClass:NSNumber.class]) return [picked doubleValue];
        }
    }
    return PLUINodeAuto;
}

static UIColor *PLUIResolveColor(id spec, UIColor *fallback) {
    if (![spec isKindOfClass:NSString.class] || [(NSString *)spec length] == 0) return fallback;
    if ([spec hasPrefix:@"$color:"]) {
        return [PLThemeManager.sharedManager colorForToken:[spec substringFromIndex:7] fallback:fallback];
    }
    return [PLThemeManager.sharedManager colorFromHex:spec] ?: fallback;
}

static UIImage *PLUIResolveImage(id spec) {
    if (![spec isKindOfClass:NSString.class] || [(NSString *)spec length] == 0) return nil;
    if ([spec hasPrefix:@"sf:"]) {
        NSString *name = [spec substringFromIndex:3];
        return [UIImage systemImageNamed:name] ?: [UIImage imageNamed:name];
    }
    if ([spec hasPrefix:@"$image:"]) {
        return [PLThemeManager.sharedManager imageForToken:[spec substringFromIndex:7]];
    }
    return nil;
}

static NSString *PLUIResolveText(id spec) {
    if (![spec isKindOfClass:NSString.class]) return nil;
    if ([spec hasPrefix:@"$i18n:"]) {
        NSString *key = [spec substringFromIndex:6];
        NSString *localized = NSLocalizedString(key, @"");
        return localized.length > 0 ? localized : key;
    }
    return spec;
}

static UIFont *PLUIFontFromStyle(NSDictionary *style) {
    CGFloat size = [style[@"font"] isKindOfClass:NSNumber.class] ? [style[@"font"] doubleValue] : 15;
    NSString *weightName = [style[@"weight"] isKindOfClass:NSString.class] ? style[@"weight"] : @"regular";
    UIFontWeight weight = UIFontWeightRegular;
    if ([weightName isEqualToString:@"medium"]) weight = UIFontWeightMedium;
    else if ([weightName isEqualToString:@"semibold"]) weight = UIFontWeightSemibold;
    else if ([weightName isEqualToString:@"bold"]) weight = UIFontWeightBold;
    else if ([weightName isEqualToString:@"light"]) weight = UIFontWeightLight;
    return [UIFont systemFontOfSize:size weight:weight];
}

static UIEdgeInsets PLUIResolvePadding(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        CGFloat inset = [value doubleValue];
        return UIEdgeInsetsMake(inset, inset, inset, inset);
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        CGFloat top = [value[@"top"] doubleValue], left = [value[@"left"] doubleValue];
        CGFloat bottom = [value[@"bottom"] doubleValue], right = [value[@"right"] doubleValue];
        return UIEdgeInsetsMake(top, left, bottom, right);
    }
    return UIEdgeInsetsZero;
}

/// 主轴分布（justify）：默认 start，非权重内容块整体居中/尾部对齐。
typedef NS_ENUM(uint8_t, PLUIJustify) {
    PLUIJustifyStart = 0,
    PLUIJustifyCenter,
    PLUIJustifyEnd,
};

/// 交叉轴对齐（crossAlign）：start/center/end 按内容尺寸对齐，stretch 铺满。
typedef NS_ENUM(uint8_t, PLUICrossAlign) {
    PLUICrossAlignStart = 0,
    PLUICrossAlignCenter,
    PLUICrossAlignEnd,
    PLUICrossAlignStretch,
};

/// "32%" → 0.32（相对父容器主/交叉轴内容长度）；非法返回 0（不按百分比布局）。
static CGFloat PLUIResolvePercent(id value) {
    if (![value isKindOfClass:NSString.class]) return 0;
    NSString *spec = (NSString *)value;
    if (![spec hasSuffix:@"%"]) return 0;
    double pct = [spec substringToIndex:spec.length - 1].doubleValue;
    if (pct <= 0 || pct > 100) return 0;
    return (CGFloat)(pct / 100.0);
}

static PLUIJustify PLUIResolveJustify(id value) {
    if (![value isKindOfClass:NSString.class]) return PLUIJustifyStart;
    NSString *spec = (NSString *)value;
    if ([spec isEqualToString:@"center"]) return PLUIJustifyCenter;
    if ([spec isEqualToString:@"end"]) return PLUIJustifyEnd;
    return PLUIJustifyStart;
}

static PLUICrossAlign PLUIResolveCrossAlign(id value) {
    // 与 flexbox 对齐：缺省 = stretch（子节点铺满交叉轴）。
    // 此前缺省按内容对齐：content 节点 sizeThatFits 为零尺寸、权重子节点测量贡献 0，
    // 整链容器交叉轴逐级坍缩（真机复现：左栏挤成窄条、内容区高 0 全黑）。
    if (![value isKindOfClass:NSString.class]) return PLUICrossAlignStretch;
    NSString *spec = (NSString *)value;
    if ([spec isEqualToString:@"center"]) return PLUICrossAlignCenter;
    if ([spec isEqualToString:@"end"]) return PLUICrossAlignEnd;
    if ([spec isEqualToString:@"stretch"]) return PLUICrossAlignStretch;
    // 显式但未知的值：保守按内容对齐（start），不拉伸
    return PLUICrossAlignStart;
}

/// 允许进入节点树的节点种类（未知种类整体丢弃，防脏数据扩散）。
static BOOL PLUIIsKnownKind(NSString *kind) {
    static NSSet<NSString *> *kinds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kinds = [NSSet setWithArray:@[@"row", @"column", @"button", @"text", @"image",
                                      @"spacer", @"divider", @"content", @"nav", @"panel", @"tileGrid"]];
    });
    return [kinds containsObject:kind];
}

@interface PLUINodeView ()
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic, assign) CGFloat weight;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, copy) NSString *bind;
@property (nonatomic, assign) BOOL contentArea;
@property (nonatomic, assign) BOOL horizontalStack;
@property (nonatomic, assign) BOOL verticalStack;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) UIEdgeInsets padding;
@property (nonatomic, assign) CGFloat fixedWidth;
@property (nonatomic, assign) CGFloat fixedHeight;
@property (nonatomic, assign) CGFloat widthPercent;   // "85%" 相对父容器主/交叉轴
@property (nonatomic, assign) CGFloat heightPercent;
@property (nonatomic, assign) PLUIJustify justify;
@property (nonatomic, assign) PLUICrossAlign crossAlign;
@property (nonatomic, assign) BOOL pillCorner;        // corner="pill"：圆角=高/2，布局时生效
@property (nonatomic, strong, nullable) CAGradientLayer *gradientLayer;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *tapGesture;
@property (nonatomic, assign) UIRectEdge outerEdges;
@property (nonatomic, copy) NSString *initialPage;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImageView *contentImageView;
@end

@implementation PLUINodeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _kind = @"view";
        _fixedWidth = PLUINodeAuto;
        _fixedHeight = PLUINodeAuto;
        _outerEdges = UIRectEdgeAll;
    }
    return self;
}

#pragma mark - 节点应用

- (BOOL)applyNode:(NSDictionary *)node
       outerEdges:(UIRectEdge)outerEdges
          compact:(BOOL)compact
             dark:(BOOL)dark {
    if (![node isKindOfClass:NSDictionary.class]) return NO;
    NSString *kind = [node[@"kind"] isKindOfClass:NSString.class] ? node[@"kind"] : nil;
    if (!kind || !PLUIIsKnownKind(kind)) return NO;
    node = PLUIMergedNode(node, compact);

    _kind = kind;
    _outerEdges = outerEdges;
    _nodeId = [node[@"id"] isKindOfClass:NSString.class] ? node[@"id"] : nil;
    _action = [node[@"action"] isKindOfClass:NSString.class] ? node[@"action"] : nil;
    _bind = [node[@"bind"] isKindOfClass:NSString.class] ? node[@"bind"] : nil;
    _weight = [node[@"weight"] isKindOfClass:NSNumber.class] ? [node[@"weight"] doubleValue] : 0;
    _spacing = [node[@"spacing"] isKindOfClass:NSNumber.class] ? [node[@"spacing"] doubleValue] : 8;
    _padding = PLUIResolvePadding(node[@"padding"]);
    _fixedWidth = PLUIResolveDimen(node[@"width"], compact);
    _fixedHeight = PLUIResolveDimen(node[@"height"], compact);
    // 百分比尺寸（"85%"）：仅在无固定值时参与布局（主轴=占父主轴比例，交叉轴同理）
    _widthPercent = isnan(_fixedWidth) ? PLUIResolvePercent(node[@"width"]) : 0;
    _heightPercent = isnan(_fixedHeight) ? PLUIResolvePercent(node[@"height"]) : 0;
    _justify = PLUIResolveJustify(node[@"justify"]);
    _crossAlign = PLUIResolveCrossAlign(node[@"crossAlign"]);
    _initialPage = [node[@"initialPage"] isKindOfClass:NSString.class] ? node[@"initialPage"] : nil;

    // 背景：字符串=纯色；字典 {from,to,angle}=线性渐变（PCL2 内容区对角渐变）
    if ([node[@"background"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *grad = node[@"background"];
        UIColor *from = PLUIResolveColor(grad[@"from"], nil);
        UIColor *to = PLUIResolveColor(grad[@"to"], nil);
        if (from && to) {
            CAGradientLayer *layer = [CAGradientLayer layer];
            layer.colors = @[(__bridge id)from.CGColor, (__bridge id)to.CGColor];
            CGFloat angle = [grad[@"angle"] isKindOfClass:NSNumber.class] ? [grad[@"angle"] doubleValue] : 45.0;
            CGFloat rad = angle * M_PI / 180.0;
            layer.startPoint = CGPointMake(0.5 - cos(rad) / 2.0, 0.5 - sin(rad) / 2.0);
            layer.endPoint = CGPointMake(0.5 + cos(rad) / 2.0, 0.5 + sin(rad) / 2.0);
            [self.layer insertSublayer:layer atIndex:0];
            _gradientLayer = layer;
            self.backgroundColor = UIColor.clearColor;
        }
    } else {
        self.backgroundColor = PLUIResolveColor(node[@"background"], self.backgroundColor);
    }

    // 描边：border = { width, color }（PCL2 白底蓝描边按钮 / 卡片描边）
    if ([node[@"border"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *border = node[@"border"];
        CGFloat bw = [border[@"width"] isKindOfClass:NSNumber.class] ? [border[@"width"] doubleValue] : 0;
        if (bw > 0) {
            self.layer.borderWidth = bw;
            self.layer.borderColor = PLUIResolveColor(border[@"color"], UIColor.separatorColor).CGColor;
        }
    }

    // 尺寸：size = 正方形边长
    CGFloat square = PLUIResolveDimen(node[@"size"], compact);
    if (!isnan(square)) {
        _fixedWidth = square;
        _fixedHeight = square;
    }

    if ([kind isEqualToString:@"row"] || [kind isEqualToString:@"column"]) {
        _horizontalStack = [kind isEqualToString:@"row"];
        _verticalStack = !_horizontalStack;
        [self applyChildren:node[@"children"] compact:compact dark:dark];
    } else if ([kind isEqualToString:@"panel"]) {
        // panel = column 容器（带默认内边距的可组合面板）
        _verticalStack = YES;
        _padding = UIEdgeInsetsEqualToEdgeInsets(_padding, UIEdgeInsetsZero)
            ? PLUIResolvePadding(@12) : _padding;
        [self applyChildren:node[@"children"] compact:compact dark:dark];
    } else if ([kind isEqualToString:@"nav"]) {
        _horizontalStack = [node[@"layout"] isEqualToString:@"horizontal"];
        _verticalStack = !_horizontalStack;
        _spacing = [node[@"spacing"] isKindOfClass:NSNumber.class] ? [node[@"spacing"] doubleValue] : 12;
        [self applyNavItems:node compact:compact dark:dark];
    } else if ([kind isEqualToString:@"content"]) {
        _contentArea = YES;
        if (_weight <= 0) _weight = 1; // 内容区默认伸展
    } else if ([kind isEqualToString:@"button"]) {
        [self buildButton:node];
    } else if ([kind isEqualToString:@"text"]) {
        [self buildText:node];
    } else if ([kind isEqualToString:@"image"]) {
        [self buildImage:node compact:compact];
    } else if ([kind isEqualToString:@"spacer"]) {
        if (_weight <= 0 && isnan(_fixedWidth) && isnan(_fixedHeight)) _weight = 1;
    } else if ([kind isEqualToString:@"divider"]) {
        self.backgroundColor = PLUIResolveColor(node[@"background"],
            [UIColor separatorColor]);
    } else if ([kind isEqualToString:@"tileGrid"]) {
        // M5 实现；先按透明容器处理，不劣化布局
    }

    [self applyCorner:node];
    [self applyVisibility:node compact:compact dark:dark];
    return YES;
}

- (void)applyChildren:(id)children compact:(BOOL)compact dark:(BOOL)dark {
    if (![children isKindOfClass:NSArray.class]) return;
    NSUInteger count = [(NSArray *)children count];
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *childNode = [(NSArray *)children objectAtIndex:i];
        // 外沿边传递：首/末子节点继承父容器对应侧，其余侧由父容器自身决定
        UIRectEdge childEdges = 0;
        if (self.horizontalStack) {
            if (i == 0) childEdges |= (self.outerEdges & UIRectEdgeLeft);
            if (i == count - 1) childEdges |= (self.outerEdges & UIRectEdgeRight);
            childEdges |= (self.outerEdges & (UIRectEdgeTop | UIRectEdgeBottom));
        } else {
            if (i == 0) childEdges |= (self.outerEdges & UIRectEdgeTop);
            if (i == count - 1) childEdges |= (self.outerEdges & UIRectEdgeBottom);
            childEdges |= (self.outerEdges & (UIRectEdgeLeft | UIRectEdgeRight));
        }
        PLUINodeView *child = [[PLUINodeView alloc] init];
        if ([child applyNode:childNode outerEdges:childEdges compact:compact dark:dark]) {
            [self addSubview:child];
        }
    }
}

- (void)applyNavItems:(NSDictionary *)node compact:(BOOL)compact dark:(BOOL)dark {
    id items = node[@"items"];
    if (![items isKindOfClass:NSArray.class]) return;
    NSMutableArray *childNodes = [NSMutableArray array];
    for (id item in (NSArray *)items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *buttonNode = [NSMutableDictionary dictionary];
        buttonNode[@"kind"] = @"button";
        if ([item[@"id"] isKindOfClass:NSString.class]) buttonNode[@"id"] = item[@"id"];
        if ([item[@"action"] isKindOfClass:NSString.class]) buttonNode[@"action"] = item[@"action"];
        if ([item[@"icon"] isKindOfClass:NSString.class]) buttonNode[@"icon"] = item[@"icon"];
        if ([item[@"label"] isKindOfClass:NSString.class]) buttonNode[@"label"] = item[@"label"];
        if ([item[@"size"] isKindOfClass:NSNumber.class]) buttonNode[@"size"] = item[@"size"];
        buttonNode[@"style"] = item[@"style"] ?: @{};
        [childNodes addObject:buttonNode];
    }
    [self applyChildren:childNodes compact:compact dark:dark];
}

- (void)buildButton:(NSDictionary *)node {
    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.translatesAutoresizingMaskIntoConstraints = YES; // 父节点手动布局
    NSDictionary *style = [node[@"style"] isKindOfClass:NSDictionary.class] ? node[@"style"] : @{};
    NSString *title = PLUIResolveText(node[@"label"] ?: node[@"text"]);
    if (title) {
        [_button setTitle:title forState:UIControlStateNormal];
        UIColor *tint = PLUIResolveColor(style[@"tint"], [UIColor labelColor]);
        [_button setTitleColor:tint forState:UIControlStateNormal];
        _button.titleLabel.font = PLUIFontFromStyle(style);
    }
    UIImage *icon = PLUIResolveImage(node[@"icon"]);
    if (icon) {
        UIColor *tint = PLUIResolveColor(style[@"tint"], nil);
        if (tint) icon = [icon imageWithTintColor:tint];
        [_button setImage:icon forState:UIControlStateNormal];
    }
    _button.backgroundColor = PLUIResolveColor(style[@"background"], _button.backgroundColor);
    // 药丸页签等图文按钮的水平内边距（节点 padding 映射到按钮 contentEdgeInsets）
    UIEdgeInsets btnPad = PLUIResolvePadding(node[@"padding"]);
    if (!UIEdgeInsetsEqualToEdgeInsets(btnPad, UIEdgeInsetsZero)) {
        _button.contentEdgeInsets = btnPad;
    }
    [self addSubview:_button];
    [_button addTarget:self action:@selector(nodeTapped:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)buildText:(NSDictionary *)node {
    _textLabel = [UILabel new];
    _textLabel.translatesAutoresizingMaskIntoConstraints = YES;
    NSDictionary *style = [node[@"style"] isKindOfClass:NSDictionary.class] ? node[@"style"] : @{};
    _textLabel.text = PLUIResolveText(node[@"text"] ?: node[@"label"]) ?: @"";
    _textLabel.font = PLUIFontFromStyle(style);
    _textLabel.textColor = PLUIResolveColor(style[@"color"], [UIColor labelColor]);
    _textLabel.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_textLabel];
}

- (void)buildImage:(NSDictionary *)node compact:(BOOL)compact {
    _contentImageView = [UIImageView new];
    _contentImageView.translatesAutoresizingMaskIntoConstraints = YES;
    _contentImageView.contentMode = UIViewContentModeScaleAspectFit;
    _contentImageView.image = PLUIResolveImage(node[@"icon"] ?: node[@"src"]);
    NSDictionary *style = [node[@"style"] isKindOfClass:NSDictionary.class] ? node[@"style"] : @{};
    _contentImageView.tintColor = PLUIResolveColor(style[@"tint"], _contentImageView.tintColor);
    _contentImageView.backgroundColor = PLUIResolveColor(node[@"background"], _contentImageView.backgroundColor);
    [self addSubview:_contentImageView];
}

- (void)applyCorner:(NSDictionary *)node {
    // "pill"：全圆药丸（PCL2 顶栏选中页签/胶囊标签），圆角=高/2，布局时应用
    if ([node[@"corner"] isKindOfClass:NSString.class] &&
        [node[@"corner"] isEqualToString:@"pill"]) {
        _pillCorner = YES;
        return;
    }
    CGFloat corner = [node[@"corner"] isKindOfClass:NSNumber.class] ? [node[@"corner"] doubleValue] : 0;
    if (corner <= 0) return;
    NSString *mask = [node[@"cornerMask"] isKindOfClass:NSString.class] ? node[@"cornerMask"] : @"all";
    self.layer.cornerRadius = corner;
    if ([mask isEqualToString:@"outer"]) {
        // 只圆"贴外"的角：两条相邻边都在外沿才生效
        CACornerMask corners = 0;
        if ((self.outerEdges & UIRectEdgeTop) && (self.outerEdges & UIRectEdgeLeft)) corners |= kCALayerMinXMinYCorner;
        if ((self.outerEdges & UIRectEdgeTop) && (self.outerEdges & UIRectEdgeRight)) corners |= kCALayerMaxXMinYCorner;
        if ((self.outerEdges & UIRectEdgeBottom) && (self.outerEdges & UIRectEdgeLeft)) corners |= kCALayerMinXMaxYCorner;
        if ((self.outerEdges & UIRectEdgeBottom) && (self.outerEdges & UIRectEdgeRight)) corners |= kCALayerMaxXMaxYCorner;
        self.layer.maskedCorners = corners;
    } else {
        self.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMinXMinYCorner
            | kCALayerMaxXMaxYCorner | kCALayerMinXMaxYCorner;
    }
}

- (void)applyVisibility:(NSDictionary *)node compact:(BOOL)compact dark:(BOOL)dark {
    NSString *visibleWhen = [node[@"visibleWhen"] isKindOfClass:NSString.class] ? node[@"visibleWhen"] : nil;
    if (!visibleWhen) return;
    BOOL visible = YES;
    if ([visibleWhen isEqualToString:@"dark"]) visible = dark;
    else if ([visibleWhen isEqualToString:@"light"]) visible = !dark;
    else if ([visibleWhen isEqualToString:@"phone"]) visible = compact;
    else if ([visibleWhen isEqualToString:@"pad"]) visible = !compact;
    self.hidden = !visible;
}

- (void)nodeTapped:(id)sender {
    if (self.tapHandler) self.tapHandler(self);
}

#pragma mark - 布局（row/column 栈：固定尺寸 + 权重分配）

- (void)layoutSubviews {
    [super layoutSubviews];

    // 药丸圆角与渐变层依赖最终 frame，在叶子/栈布局前先应用
    if (_pillCorner) self.layer.cornerRadius = self.bounds.size.height / 2.0;
    if (_gradientLayer) _gradientLayer.frame = self.bounds;

    // 叶子内容贴合自身 bounds。必须在栈早退之前执行：button/text/image 都是
    // 叶子节点（非 stack），早退后它们的 UIKit 子视图永远停留在 CGRectZero
    // ——按钮/文字整体不可见，只剩容器背景色（真机首渲即暴露）。
    if (self.textLabel) self.textLabel.frame = self.bounds;
    if (self.contentImageView) self.contentImageView.frame = self.bounds;
    // 按钮铺满节点：宽文字按钮（如 PCL2 启动按钮）与图标按钮都能正确渲染，
    // UIButton 自身负责图文内容居中。此前按 min(宽,高) 居中裁切文字按钮。
    if (self.button) self.button.frame = self.bounds;

    if (!self.horizontalStack && !self.verticalStack) return;
    BOOL horizontal = self.horizontalStack;

    NSArray<PLUINodeView *> *children = [self.subviews isKindOfClass:NSArray.class] ? (NSArray *)self.subviews : nil;
    if (children.count == 0) return;

    UIEdgeInsets pad = self.padding;
    CGFloat mainLen = horizontal ? self.bounds.size.width - pad.left - pad.right
                                 : self.bounds.size.height - pad.top - pad.bottom;
    CGFloat crossLen = horizontal ? self.bounds.size.height - pad.top - pad.bottom
                                  : self.bounds.size.width - pad.left - pad.right;
    if (mainLen <= 0 || crossLen <= 0) return;

    NSUInteger n = children.count;
    CGFloat spacingTotal = self.spacing * (CGFloat)(n - 1);
    CGFloat fixedTotal = 0;
    CGFloat weightSum = 0;
    NSMutableArray<NSNumber *> *mains = [NSMutableArray arrayWithCapacity:n];
    for (UIView *sub in children) {
        CGFloat main = PLUINodeAuto;
        if (![sub isKindOfClass:PLUINodeView.class]) { [mains addObject:@(0)]; continue; }
        PLUINodeView *child = (PLUINodeView *)sub;
        if (child.weight > 0) {
            weightSum += child.weight;
        } else if (horizontal && child.widthPercent > 0) {
            // 主轴百分比："32%" 占父主轴内容长度（PCL2 左栏 32% 宽）
            main = child.widthPercent * mainLen;
        } else if (!horizontal && child.heightPercent > 0) {
            main = child.heightPercent * mainLen;
        } else if (horizontal && !isnan(child.fixedWidth)) {
            main = child.fixedWidth;
        } else if (!horizontal && !isnan(child.fixedHeight)) {
            main = child.fixedHeight;
        } else {
            main = [child preferredMainSizeForCrossSize:crossLen horizontal:horizontal];
            if (isnan(main)) main = 0;
        }
        [mains addObject:@(isnan(main) ? NAN : main)];
        if (!isnan(main)) fixedTotal += main;
    }

    CGFloat weightedAvail = mainLen - spacingTotal - fixedTotal;
    if (weightedAvail < 0) weightedAvail = 0;

    // 主轴分布：非权重内容块的整体偏移（PCL2 启动按钮两行文字垂直居中）
    CGFloat leadingExtra = 0;
    if (_justify == PLUIJustifyCenter) {
        leadingExtra = (mainLen - spacingTotal - fixedTotal) / 2.0;
    } else if (_justify == PLUIJustifyEnd) {
        leadingExtra = mainLen - spacingTotal - fixedTotal;
    }
    if (leadingExtra < 0) leadingExtra = 0;

    CGFloat offset = (horizontal ? pad.left : pad.top) + leadingExtra;
    for (NSUInteger i = 0; i < n; i++) {
        PLUINodeView *child = children[i];
        CGFloat main = mains[i].doubleValue;
        if (isnan(main)) {
            main = (weightSum > 0 && child.weight > 0) ? weightedAvail * child.weight / weightSum : 0;
        }

        // 交叉轴尺寸（flex 语义）：百分比 > 固定尺寸 > stretch 铺满 > 按内容对齐
        // 固定尺寸优先于 stretch：PCL2 固定高药丸在默认 stretch 容器内保持原高不被拉变形
        CGFloat crossPct = horizontal ? child.heightPercent : child.widthPercent;
        CGFloat fixedCross = horizontal ? child.fixedHeight : child.fixedWidth;
        CGFloat childCross;
        if (crossPct > 0) {
            childCross = crossPct * crossLen;
        } else if (!isnan(fixedCross)) {
            childCross = fixedCross;
        } else if (_crossAlign == PLUICrossAlignStretch) {
            childCross = crossLen;
        } else {
            CGSize fit = [child sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
            childCross = horizontal ? fit.height : fit.width;
        }
        if (childCross > crossLen) childCross = crossLen;
        CGFloat alignFactor = (_crossAlign == PLUICrossAlignCenter) ? 0.5
                          : ((_crossAlign == PLUICrossAlignEnd) ? 1.0 : 0.0);
        CGFloat crossOffset = (horizontal ? pad.top : pad.left) + (crossLen - childCross) * alignFactor;

        if (horizontal) {
            child.frame = CGRectMake(offset, crossOffset, main, childCross);
        } else {
            child.frame = CGRectMake(crossOffset, offset, childCross, main);
        }
        offset += main + self.spacing;
    }
}

- (CGFloat)preferredMainSizeForCrossSize:(CGFloat)crossSize horizontal:(BOOL)horizontal {
    CGSize fit = [self sizeThatFits:CGSizeMake(horizontal ? CGFLOAT_MAX : crossSize,
                                                horizontal ? crossSize : CGFLOAT_MAX)];
    return horizontal ? fit.width : fit.height;
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (self.textLabel) return [self.textLabel sizeThatFits:size];
    if (self.button) {
        CGSize intrinsic = self.button.intrinsicContentSize;
        return CGSizeMake(intrinsic.width + 8, intrinsic.height + 4);
    }
    if (self.contentImageView) {
        if (!isnan(self.fixedWidth) && !isnan(self.fixedHeight)) return CGSizeMake(self.fixedWidth, self.fixedHeight);
        UIImage *image = self.contentImageView.image;
        if (image) {
            CGSize s = image.size;
            // 固有尺寸查询（双向无约束）：直接返回原始尺寸，避免 aspect-fit 比例溢出
            if (size.width >= CGFLOAT_MAX && size.height >= CGFLOAT_MAX) return s;
            CGFloat scale = MIN(size.width / s.width, size.height / s.height);
            if (scale > 0 && !isinf(scale)) return CGSizeMake(s.width * scale, s.height * scale);
            return s;
        }
        return CGSizeZero;
    }
    if ([self.kind isEqualToString:@"divider"]) return CGSizeMake(1, 1); // 主轴 1pt
    // 容器（row/column/nav/panel）：按子节点聚合测量，嵌套容器在父栈中拿到合理首选尺寸。
    // 此前容器返回 CGSizeZero，嵌套 row/column 在列/行里高度/宽度塌为 0。
    if (self.horizontalStack || self.verticalStack) {
        BOOL horizontal = self.horizontalStack;
        UIEdgeInsets pad = self.padding;
        CGFloat main = 0, cross = 0;
        NSUInteger count = 0;
        for (UIView *sub in self.subviews) {
            if (![sub isKindOfClass:PLUINodeView.class]) continue;
            PLUINodeView *child = (PLUINodeView *)sub;
            count++;
            // 权重子节点无法预知分配量，退化为固有尺寸作为估计值
            CGSize intrinsic = [child sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
            CGFloat childMain, childCross;
            if (horizontal) {
                childMain = !isnan(child.fixedWidth) ? child.fixedWidth
                          : [child preferredMainSizeForCrossSize:CGFLOAT_MAX horizontal:YES];
                childCross = !isnan(child.fixedHeight) ? child.fixedHeight : intrinsic.height;
            } else {
                childMain = !isnan(child.fixedHeight) ? child.fixedHeight
                          : [child preferredMainSizeForCrossSize:CGFLOAT_MAX horizontal:NO];
                childCross = !isnan(child.fixedWidth) ? child.fixedWidth : intrinsic.width;
            }
            if (isnan(childMain)) childMain = 0;
            main += childMain;
            cross = MAX(cross, childCross);
        }
        if (count > 1) main += self.spacing * (CGFloat)(count - 1);
        main += horizontal ? (pad.left + pad.right) : (pad.top + pad.bottom);
        cross += horizontal ? (pad.top + pad.bottom) : (pad.left + pad.right);
        return horizontal ? CGSizeMake(main, cross) : CGSizeMake(cross, main);
    }
    return CGSizeZero;
}

- (CGSize)intrinsicContentSize {
    return [self sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
}

#pragma mark - 文本/图片读写（launcher.view 句柄落点）

- (void)updateText:(NSString *)text {
    if (self.textLabel) {
        self.textLabel.text = text ?: @"";
    } else if (self.button) {
        [self.button setTitle:text forState:UIControlStateNormal];
    }
    [self setNeedsLayout];
}

- (NSString *)currentText {
    if (self.textLabel) return self.textLabel.text;
    if (self.button) return [self.button titleForState:UIControlStateNormal];
    return nil;
}

- (void)updateImageSpec:(NSString *)imageSpec {
    UIImage *image = PLUIResolveImage(imageSpec);
    if (self.contentImageView) self.contentImageView.image = image;
    else if (self.button && image) [self.button setImage:image forState:UIControlStateNormal];
}

- (void)updateTextColorSpec:(NSString *)colorSpec {
    UIColor *color = PLUIResolveColor(colorSpec, nil);
    if (!color) return;
    if (self.textLabel) self.textLabel.textColor = color;
    else if (self.button) [self.button setTitleColor:color forState:UIControlStateNormal];
}

- (void)updateEnabled:(BOOL)enabled {
    if (self.button) self.button.enabled = enabled;
}

#pragma mark - 手势与样式（launcher.view(id):setStyle / 容器可点击）

- (BOOL)hasButtonControl {
    return self.button != nil;
}

- (void)attachTapGestureIfNeeded {
    // 带动作的非按钮节点（如 PCL2 两行启动按钮 = column + 两个 text）挂轻点手势；
    // cancelsTouchesInView=NO 不拦截内嵌 UIButton 的触摸（若包作者混用，动作会双发，
    // 由包自行避免"容器带 action 且内含 action 按钮"的组合）。
    if (self.action.length == 0 || self.button) return;
    if (_tapGesture) return;
    _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nodeTapped:)];
    _tapGesture.cancelsTouchesInView = NO;
    self.userInteractionEnabled = YES;
    [self addGestureRecognizer:_tapGesture];
}

- (void)updateStyleSpec:(NSDictionary *)spec {
    if (![spec isKindOfClass:NSDictionary.class]) return;
    id bg = spec[@"background"];
    if ([bg isKindOfClass:NSString.class] && [(NSString *)bg length] > 0) {
        // 动态样式不支持渐变（渐变节点不在 setStyle 目标之列）
        if (_gradientLayer) {
            [_gradientLayer removeFromSuperlayer];
            _gradientLayer = nil;
        }
        self.backgroundColor = PLUIResolveColor(bg, self.backgroundColor);
    }
    id tint = spec[@"tint"];
    if ([tint isKindOfClass:NSString.class]) {
        UIColor *color = PLUIResolveColor(tint, nil);
        if (color) {
            if (self.button) [self.button setTitleColor:color forState:UIControlStateNormal];
            if (self.textLabel) self.textLabel.textColor = color;
        }
    }
    id bw = spec[@"borderWidth"];
    if ([bw isKindOfClass:NSNumber.class]) self.layer.borderWidth = [bw doubleValue];
    id bc = spec[@"borderColor"];
    if ([bc isKindOfClass:NSString.class]) {
        UIColor *color = PLUIResolveColor(bc, nil);
        if (color) self.layer.borderColor = color.CGColor;
    }
    id corner = spec[@"corner"];
    if ([corner isKindOfClass:NSString.class] && [corner isEqualToString:@"pill"]) {
        _pillCorner = YES;
    } else if ([corner isKindOfClass:NSNumber.class]) {
        _pillCorner = NO;
        self.layer.cornerRadius = [corner doubleValue];
    }
    [self setNeedsLayout];
}

#pragma mark - 元数据

- (NSUInteger)nodeCount {
    NSUInteger count = 1;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:PLUINodeView.class]) count += [(PLUINodeView *)sub nodeCount];
    }
    return count;
}

@end
