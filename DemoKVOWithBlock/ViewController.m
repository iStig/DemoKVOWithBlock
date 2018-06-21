//
//  ViewController.m
//  DemoKVOWithBlock
//
//  Created by iStig on 2018/5/29.
//  Copyright © 2018年 iStig. All rights reserved.
//

#import "ViewController.h"
#import "NSObject+ISKVOBlock.h"
#import <objc/runtime.h>

@interface Message : NSObject

@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSString *des;
@end

@implementation Message
- (NSString *)descriptionLog {
    return @"descriptionLog";
}

//- (void)setText:(NSString *)text {
//    NSLog(@"text change: %@",text);
//}

//- (NSString *)text {
//    return @"AAA";
//}

@end

@interface ViewController ()
@property (nonatomic, weak) IBOutlet UITextField *textfield;
@property (nonatomic, strong) Message *message;
@property (nonatomic, strong) Message *messageNoObserver;

@end

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    self.messageNoObserver = [[Message alloc] init];
    self.message = [[Message alloc] init];
    [self.message IS_addObserver:self forKey:NSStringFromSelector(@selector(text))
                       withBlock:^(id observedObject, NSString *observedKey, id oldValue, id newValue) {
                           NSLog(@"\n %@.%@ is now: %@ \n is old: %@", observedObject, observedKey, newValue,oldValue);
                           dispatch_async(dispatch_get_main_queue(), ^{
                               self.textfield.text = newValue;
                           });
                       }];

  //用来测试不替换class方法的情况
    PrintDescription(@"messageNoObserver",self.messageNoObserver);
    PrintDescription(@"message",self.message);
    
    NSLog(@"\n Using NSObject methods:\n normal setText: is %p,\n overridden setText: is %p\n",
           [self.messageNoObserver methodForSelector:@selector(setText:)],
           [self.message methodForSelector:@selector(setText:)]);
    NSLog(@"\n Using libobjc functions:\n normal setText: is %p,\n overridden setText: is %p\n",
           method_getImplementation(class_getInstanceMethod(object_getClass(self.messageNoObserver),
                                                            @selector(setText:))),
           method_getImplementation(class_getInstanceMethod(object_getClass(self.message),
                                                            @selector(setText:))));
    [self changeMessage:nil];
}

- (IBAction)changeMessage:(id)sender
{
    NSArray *msgs = @[@"Nodejs", @"Objective C", @"Swift", @"Python", @"Kotlin", @"Java", @"Go"];
    NSUInteger index = arc4random_uniform((u_int32_t)msgs.count);
    self.message.text = msgs[index];
    NSLog(@"SELF.MESSAGE.TEXT %@",self.message.text);
}


- (void)dealloc {
    [self.message IS_removeObserver:self forKey:NSStringFromSelector(@selector(text))];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
