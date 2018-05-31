//
//  NSObject+ISKVOBlock.m
//  DemoKVOWithBlock
//
//  Created by iStig on 2018/5/29.
//  Copyright © 2018年 iStig. All rights reserved.
//

#import "NSObject+ISKVOBlock.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kISKVOClassPrefix = @"ISKVOClassPrefix_";
static void *const  kISKVOAssociatedObservers =  (void *)&kISKVOAssociatedObservers;

#pragma mark - ISObservationInfo
@interface ISObservationInfo:NSObject
@property (nonatomic, weak) NSObject *observer;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) ISObservingBlock block;
@end

@implementation ISObservationInfo

- (instancetype)initWithObserver:(id)observer
                             key:(NSString *)key
                           block:(ISObservingBlock)block
{
    self = [super init];
    if (self) {
        _observer = observer;
        _key = key;
        _block = block;
    }
    
    return self;
}

@end

#pragma mark - Debug Help Methods
static NSArray *ClassMethodNames(Class c)
{
    NSMutableArray *array = [NSMutableArray array];
    
    unsigned int methodCount = 0;
    Method *methodList = class_copyMethodList(c, &methodCount);
    unsigned int i;
    for(i = 0; i < methodCount; i++) {
        [array addObject: NSStringFromSelector(method_getName(methodList[i]))];
    }
    free(methodList);
    
    return array;
}

#pragma mark - Public Method
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
void PrintDescription(NSString *name, id obj)
{
    NSString *str = [NSString stringWithFormat:
                     @"%@: %@\n\tNSObject class %s\n\tRuntime class %s\n\timplements methods <%@>\n\n",
                     name,
                     obj,
                     class_getName([obj class]),
                     class_getName(object_getClass(obj)),
                     [ClassMethodNames(object_getClass(obj)) componentsJoinedByString:@", "]];
    printf("\n\t%s\n", [str UTF8String]);
}
#pragma clang diagnostic pop

#pragma mark - Helpers
static NSString * getterForSetter(NSString *setter)
{
    if (setter.length <=4 || ![setter hasPrefix:@"set"] || ![setter hasSuffix:@":"]) {
         @throw [NSException exceptionWithName:@"CKKVO Error" reason:@"set方法not available" userInfo:nil];
        return nil;
    }
    
    // remove 'set' at the begining and ':' at the end
    NSRange range = NSMakeRange(3, setter.length - 4);
    NSString *key = [setter substringWithRange:range];
    
    // lower case the first letter
    NSString *firstLetter = [[key substringToIndex:1] lowercaseString];
    key = [key stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                       withString:firstLetter];
    
    return key;
}

static NSString * setterForGetter(NSString *getter)
{
    if (getter.length <= 0) {
         @throw [NSException exceptionWithName:@"CKKVO Error" reason:@"没有对应的key" userInfo:nil];
        return nil;
    }
    
    // upper case the first letter
    NSString *firstLetter = [[getter substringToIndex:1] uppercaseString];
    NSString *remainingLetters = [getter substringFromIndex:1];
    
    // add 'set' at the begining and ':' at the end
    NSString *setter = [NSString stringWithFormat:@"set%@%@:", firstLetter, remainingLetters];
    
    return setter;
}



/**
 1. 获取旧值。
 2. 创建super的结构体，并向super发送属性的消息。这一步不是必须的。系统kvo api没有这一步的实现。一般都是手动调用[super _cmd]
 3. 遍历调用block。
 */
#pragma mark - Overridden Methods
static void kvo_setter(id self, SEL _cmd, id newValue)
{
    //1.
    NSString *setterName = NSStringFromSelector(_cmd);
    NSString *getterName = getterForSetter(setterName);
    
    if (!getterName) {
        NSString *reason = [NSString stringWithFormat:@"Object %@ does not have setter %@", self, setterName];
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:reason
                                     userInfo:nil];
        return;
    }
    
    id oldValue = [self valueForKey:getterName];
    
    //2.
    struct objc_super superclazz = {
        .receiver = self,
        .super_class = class_getSuperclass(object_getClass(self))
    };
    
    // cast our pointer so the compiler won't complain
    void (*objc_msgSendSuperCasted)(void *, SEL, id) = (void *)objc_msgSendSuper;
    
    // call super's setter, which is original class's setter method
    objc_msgSendSuperCasted(&superclazz, _cmd, newValue);
    
    //3.
    // look up observers and call the blocks
    NSMutableArray *observers = objc_getAssociatedObject(self,kISKVOAssociatedObservers);
    for (ISObservationInfo *each in observers) {
        if ([each.key isEqualToString:getterName]) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                each.block(self, getterName, oldValue, newValue);
            });
        }
    }
}

static Class kvo_class(id self, SEL _cmd)
{
    return class_getSuperclass(object_getClass(self));
}

#pragma mark - KVO Category
@implementation NSObject (ISKVOBlock)
/**
 1. 通过Method判断是否有这个key对应的selector，如果没有则Crash。
 2. 判断当前类是否是KVO子类，如果不是则创建，并设置其isa指针。
 3. 如果没有实现，则添加Key对应的setter方法。
 4. 将调用对象添加到数组中。
 */
- (void)IS_addObserver:(NSObject *)observer
                forKey:(NSString *)key
             withBlock:(ISObservingBlock)block
{
    //1.
    SEL setterSelector = NSSelectorFromString(setterForGetter(key));
    Method setterMethod = class_getInstanceMethod(object_getClass(self), setterSelector);
    if (!setterMethod) {
        NSString *reason = [NSString stringWithFormat:@"Object %@ does not have a setter for key %@", self, key];
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:reason
                                     userInfo:nil];
        return;
    }
    
     //2.
    Class clazz = object_getClass(self);
    NSString *clazzName = NSStringFromClass(clazz);
    
    // if not an KVO class yet
    if (![clazzName hasPrefix:kISKVOClassPrefix]) {
        clazz = [self makeKvoClassWithOriginalClassName:clazzName];
        object_setClass(self, clazz);
    }
    
    //3.
    // add our kvo setter if this class (not superclasses) doesn't implement the setter?
    if (![self hasSelector:setterSelector]) {
        const char *types = method_getTypeEncoding(setterMethod);
        class_addMethod(clazz, setterSelector, (IMP)kvo_setter, types);
    }
    
    // 4.
    ISObservationInfo *info = [[ISObservationInfo alloc] initWithObserver:observer key:key block:block];
    NSMutableArray *observers = objc_getAssociatedObject(self, kISKVOAssociatedObservers);
    if (!observers) {
        observers = [NSMutableArray array];
    }
    [observers addObject:info];
    objc_setAssociatedObject(self,kISKVOAssociatedObservers, observers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


- (void)IS_removeObserver:(NSObject *)observer forKey:(NSString *)key
{
    NSMutableArray* observers = objc_getAssociatedObject(self, kISKVOAssociatedObservers);
    
    ISObservationInfo *infoToRemove;
    for (ISObservationInfo* info in observers) {
        if (info.observer == observer && [info.key isEqual:key]) {
            infoToRemove = info;
            break;
        }
    }
    
    [observers removeObject:infoToRemove];
}


/**
 1. 判断是否存在KVO类，如果存在则返回。
 2. 如果不存在，则创建KVO类。
 3. 重写KVO类的class方法，指向自定义的IMP。
 */
- (Class)makeKvoClassWithOriginalClassName:(NSString *)originalClazzName
{
    // 1.
    NSString *kvoClazzName = [kISKVOClassPrefix stringByAppendingString:originalClazzName];
    Class clazz = NSClassFromString(kvoClazzName);
    
    if (clazz) {
        return clazz;
    }
    
    //2.
    // class doesn't exist yet, make it
    Class originalClazz = object_getClass(self);
    Class kvoClazz = objc_allocateClassPair(originalClazz, kvoClazzName.UTF8String, 0);
    
    //3.
    // grab class method's signature so we can borrow it
    Method clazzMethod = class_getInstanceMethod(originalClazz, @selector(class));
    const char *types = method_getTypeEncoding(clazzMethod);
    class_addMethod(kvoClazz, @selector(class), (IMP)kvo_class, types);
    
    objc_registerClassPair(kvoClazz);
    
    return kvoClazz;
}


- (BOOL)hasSelector:(SEL)selector
{
    Class clazz = object_getClass(self);
    unsigned int methodCount = 0;
    Method* methodList = class_copyMethodList(clazz, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL thisSelector = method_getName(methodList[i]);
        if (thisSelector == selector) {
            free(methodList);
            return YES;
        }
    }
    
    free(methodList);
    return NO;
}

@end


