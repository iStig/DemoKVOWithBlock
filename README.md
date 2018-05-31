# DemoKVOWithBlock
##KVO底层原理及Block方式回调实现

###前言
1. 本文不详细概述 `KVO` 的用法，只结合网上的资料说说对这种技术的底层实现原理。如需参考具体用法移步[ KVO具体应用](https://github.com/Azuo520/KVO-Demo)
2. 本文探究底层技术参考来源[最新官方开源代码objc4-723](https://opensource.apple.com/source/objc4/objc4-723/) 需要对`runtime`有一定深度的了解参考[Runtime 你为何如此之屌？](https://www.jianshu.com/p/902749ed3e4c)
3. 本文具体实现 `KVO` 功能通过Block方式回调，增加 `KVO` ds的使用体验。具体实现参考[源码](https://github.com/iStig/DemoKVOWithBlock)


###概述
`KVO (Key-Value Observing)` 是苹果提供的一套事件通知机制。允许对象监听另一个对象特定属性的改变，并在改变时接收到事件。由于 `KVO` 的实现机制，所以对属性才会发生作用，一般继承自 `NSObject` 的对象都默认支持 `KVO`。

`KVO` 和 `NSNotificationCenter` 都是 `iOS` 中观察者模式的一种实现。区别在于，相对于被观察者和观察者之间的关系，`KVO` 是一对一的，而`NSNotificationCenter`是一对多的。`KVO` 对被监听对象无侵入性，不需要修改其内部代码即可实现监听。

`KVO` 的实现依赖于 OC 强大的 `Runtime`
`KVO` 是 `Cocoa` 提供的一种基于 `KVC` 的机制


##实现原理
`KVO` 是通过 `isa-swizzling` 技术实现的(这句话是整个 `KVO` 实现的重点)。

1. 当某个类的属性对象第一次被观察时，系统就会在运行期动态地创建该类的一个派生类(子类)，在这个派生类中重写基类(父类)中任何被观察属性的setter 方法。派生类在被重写的setter方法内实现真正的通知机制。

2. 如果原类为Person，那么生成的派生类名为NSKVONotifying_Person
，每个类对象中都有一个isa指针指向当前类，当一个类对象的第一次被观察监听，那么系统会偷偷将isa指针指向动态生成的派生类，从而在给被监控属性赋值时执行的是派生类的setter方法。

3. 键值观察通知依赖于NSObject 的两个方法: willChangeValueForKey: 和 didChangevlueForKey:在一个被观察属性发生改变之前， willChangeValueForKey:一定会被调用，这就会记录旧的值。而当改变发生后，didChangeValueForKey:会被调用，继而 observeValueForKey:ofObject:change:context: 也会被调用。

4. KVO的这套实现机制中苹果还偷偷重写了class方法，让我们误认为还是使用的当前类，从而达到隐藏生成的派生类

##代码解析

```
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
```

1.  通过Method判断是否有这个key对应的selector，如果没有则Crash。
2.  判断当前类是否是KVO子类，如果不是则创建，并设置其isa指针。
3.  如果没有实现，则添加Key对应的setter方法。
4.  将调用对象添加到数组中。


```
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

```

1.  获取旧值。
2.  创建super的结构体，并向super发送属性的消息。这一步不是必须的。系统kvo api没有这一步的实现。
3.  遍历调用block。

```
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
```
遍历观察者对象数组,移除指定观察者对象。


##扩展问题

1.  [ARC下dealloc过程及.cxx_destruct的探究] (http://blog.sunnyxx.com/2014/04/02/objc_dig_arc_dealloc/)
~~~
messageNoObserver: <Message: 0x60400000aeb0>
NSObject class Message
Runtime class Message
implements methods <.cxx_destruct, text, setText:>

message: <Message: 0x604000002f50>
NSObject class Message
Runtime class ISKVOClassPrefix_Message
implements methods <setText:, class>
~~~

2. [KVO原理分析及使用进阶](https://www.jianshu.com/p/badf5cac0130) __测试代码__ 描述了通过系统API调用KVO前打印信息中有`method Name = dealloc` 对于这个方法怎么理解？
~~~
//使用kvo前
object address : 0x604000239340
object setName: IMP 0x10ea8defe object setAge: IMP 0x10ea94106
objectMethodClass : KVOObject, ObjectRuntimeClass : NSKVONotifying_KVOObject, superClass : KVOObject
object method list
method Name = setAge:
method Name = setName:
method Name = class
method Name = dealloc
method Name = _isKVOA

//使用kvo后
object address : 0x604000237920
object setName: IMP 0x10ddc2770 object setAge: IMP 0x10ddc27d0
objectMethodClass : KVOObject, ObjectRuntimeClass : KVOObject, superClass : NSObject
object method list
method Name = .cxx_destruct
method Name = description
method Name = name
method Name = setName:
method Name = setAge:
method Name = age
~~~


##参考文章解读以及推荐阅读星级(🌟）——（🌟🌟🌟🌟🌟)
🌟🌟🌟🌟🌟[KVO原理分析及使用进阶](https://www.jianshu.com/p/badf5cac0130)
>1.KVO Cocoa Foundation API使用解析  
2.isa指针理解(便于理解 `isa-swizzling` 技术)
3.详细的KVO缺点描述
4.手写KVO Block具体实现并阐述了使用手写kvo的注意事项
5.推荐使用手写KVO的使用方式 `KVOController` 提供该开源项目源码解析

🌟🌟🌟🌟[ KVO具体应用](https://github.com/Azuo520/KVO-Demo)
>1.详细描述了KVO的使用
2.详细的原理介绍
3.特别突出的是对 `NSNotificationCenter` `Delegate` `KVO`进行了详细的横向对比
4.扩展了KVO相关问题
5.Github项目代码

🌟🌟🌟🌟[KVC/KVO原理详解及编程指南](https://blog.csdn.net/iunion/article/details/46890809)
>1.详细的代码示例
2.对KVC有特别详尽的使用和原理解析
3.提供结论涉及KVO/KVC的多种使用方式优缺点。

🌟🌟🌟🌟[Runtime 你为何如此之屌？](https://www.jianshu.com/p/902749ed3e4c)
>从苹果开源代码的角度详细描述了runtime的理解和使用

🌟🌟[探究KVO的底层实现原理](https://www.jianshu.com/p/829864680648)
>1.简单描述KVO/KVC实现原理 
2.附有原理实现图和代码引用
3.引用的文章不错🌟🌟🌟[如何自己动手实现 KVO](http://tech.glowing.com/cn/implement-kvo/)
