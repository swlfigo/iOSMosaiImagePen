//
//  ViewController.m
//  MosaiDemo
//
//  Created by Sylar on 2018/4/2.
//  Copyright © 2018年 Sylar. All rights reserved.
//

#import "ViewController.h"
#import "MosaiView.h"

@interface ViewController ()<MosaiViewDelegate>

@property (nonatomic, strong) MosaiView *mosaicView;


//马赛克底层图
@property(nonatomic, strong)NSMutableArray *mosaiSourceArray;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self initView];
}

- (void)initView{
    
    _mosaiSourceArray = [[NSMutableArray alloc]init];
    
    
    UIImage *img = [UIImage imageNamed:@"cat.jpg"];
    UIImage *newImg = [[self class] mosaicImage:img mosaicLevel:20];
    CGFloat ScreenWidth = [[UIScreen mainScreen] bounds].size.width;
    CGFloat ScreenHeight = [[UIScreen mainScreen] bounds].size.height;
    CGFloat imageSizeWidth = img.size.width;
    CGFloat imageSizeHeight = img.size.height;
    CGFloat height = 0.0f;
    CGFloat scale = ScreenWidth * imageSizeHeight / imageSizeWidth;
    
    
    self.mosaicView = [[MosaiView alloc] initWithFrame:CGRectMake(0, 100, ScreenWidth, scale)];
    self.mosaicView.deleagate = self;
    //添加马赛克图
    [_mosaiSourceArray addObject:newImg];
    [_mosaiSourceArray addObject:[UIImage imageNamed:@"mosai1.jpg"]];
    [_mosaiSourceArray addObject:[UIImage imageNamed:@"mosai2.jpg"]];
    [_mosaiSourceArray addObject:[UIImage imageNamed:@"mosai3.jpg"]];
    
    
    self.mosaicView.originalImage = img;
    self.mosaicView.mosaicImage = newImg;
    [self.view addSubview:self.mosaicView];
    
    
    //Btn
    UIButton *render = [[UIButton alloc]initWithFrame:CGRectMake(0, 0, 100, 100)];
    [render setTitle:@"render" forState:UIControlStateNormal];
    [render setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [self.view addSubview:render];
    [render addTarget:self action:@selector(render) forControlEvents:UIControlEventTouchUpInside];
    
    //Mosai
    UIView *mosaiSelectedView = [[UIView alloc]initWithFrame:CGRectMake(0, 0, 20, 20)];
    mosaiSelectedView.backgroundColor = [UIColor redColor];
    mosaiSelectedView.tag = 6000;
    mosaiSelectedView.userInteractionEnabled = NO;
    [self.view addSubview:mosaiSelectedView];
    
    for (int i = 0 ; i < self.mosaiSourceArray.count; ++i) {
        UIButton *mosaiBtn = [[UIButton alloc]init];
        [mosaiBtn setBackgroundImage:self.mosaiSourceArray[i] forState:UIControlStateNormal];
        [self.view addSubview:mosaiBtn];
        mosaiBtn.tag = 9000 + i;
        mosaiBtn.frame = CGRectMake(60 * i, ScreenHeight - 60, 60, 60);
        if (i == 0  ) {
            //默认第一个马赛克图案选中
            UIView *view = [self.view viewWithTag:6000];
            view.center = CGPointMake(CGRectGetMidX(mosaiBtn.frame), CGRectGetMidY(mosaiBtn.frame));
        }
        [mosaiBtn addTarget:self action:@selector(changeMosaiStyle:) forControlEvents:UIControlEventTouchUpInside];
    }
    [self.view bringSubviewToFront:mosaiSelectedView];
    
    
    //Redo Undo
    UIButton *undo = [[UIButton alloc]initWithFrame:CGRectMake(0, ScreenHeight - 70 - 22, 22, 22)];
    [undo setBackgroundImage:[UIImage imageNamed:@"beautySeniorUndo"] forState:UIControlStateNormal];
    [self.view addSubview:undo];
    [undo addTarget:self action:@selector(undoRedo:) forControlEvents:UIControlEventTouchUpInside];
    undo.tag = 8000;

    
    UIButton *redo = [[UIButton alloc]initWithFrame:CGRectMake(30, ScreenHeight - 70 - 22, 22, 22)];
    [redo setBackgroundImage:[UIImage imageNamed:@"beautySeniorRedo"] forState:UIControlStateNormal];
    [self.view addSubview:redo];
    [redo addTarget:self action:@selector(undoRedo:) forControlEvents:UIControlEventTouchUpInside];
    redo.tag = 8001;
    
//    CountLabel
    UILabel *operationCountLabel = [[UILabel alloc]initWithFrame:CGRectMake(60, ScreenHeight - 70 - 22, 300, 22)];
    operationCountLabel.text = @"操作数:0次,当前操作数:0次";
    operationCountLabel.textColor = [UIColor blackColor];
    operationCountLabel.tag = 5000;
    [self.view addSubview:operationCountLabel];

}



-(void)undoRedo:(UIButton*)sender{
    if (sender.tag == 8000) {
        [self.mosaicView undo];
    }else if (sender.tag == 8001){
        [self.mosaicView redo];
    }
    UILabel *operationLabel = [self.view viewWithTag:5000];
    operationLabel.text = [NSString stringWithFormat:@"操作数:%ld次,当前操作数:%ld次",self.mosaicView.operationCount,self.mosaicView.currentIndex];
}


-(void)mosaiView:(MosaiView *)view TouchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event{
    UILabel *operationLabel = [self.view viewWithTag:5000];
    operationLabel.text = [NSString stringWithFormat:@"操作数:%ld次,当前操作数:%ld次",self.mosaicView.operationCount,self.mosaicView.currentIndex];
}

-(void)render{
    //    [self.mosaicView render];
}

//更换马赛克
-(void)changeMosaiStyle:(UIButton*)sender{
    UIView *mosaiBtn = [self.view viewWithTag:sender.tag];
    UIView *view = [self.view viewWithTag:6000];
    view.center = CGPointMake(CGRectGetMidX(mosaiBtn.frame), CGRectGetMidY(mosaiBtn.frame));
    
    self.mosaicView.mosaicImage = self.mosaiSourceArray[sender.tag - 9000];
//    [self.mosaicView resetMosaiImage];
}

//生成原图马赛克
+(UIImage *)mosaicImage:(UIImage *)sourceImage mosaicLevel:(NSUInteger)level{
    
    //1、这一部分是为了把原始图片转成位图，位图再转成可操作的数据
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();//颜色通道
    CGImageRef imageRef = sourceImage.CGImage;//位图
    CGFloat width = CGImageGetWidth(imageRef);//位图宽
    CGFloat height = CGImageGetHeight(imageRef);//位图高
    CGContextRef context = CGBitmapContextCreate(nil, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast);//生成上下午
    CGContextDrawImage(context, CGRectMake(0.0f, 0.0f, width, height), imageRef);//绘制图片到上下文中
    unsigned char *bitmapData = CGBitmapContextGetData(context);//获取位图的数据
    
    
    //2、这一部分是往右往下填充色值
    NSUInteger index,preIndex;
    unsigned char pixel[4] = {0};
    for (int i = 0; i < height; i++) {//表示高，也可以说是行
        for (int j = 0; j < width; j++) {//表示宽，也可以说是列
            index = i * width + j;
            if (i % level == 0) {
                if (j % level == 0) {
                    //把当前的色值数据保存一份，开始为i=0，j=0，所以一开始会保留一份
                    memcpy(pixel, bitmapData + index * 4, 4);
                }else{
                    //把上一次保留的色值数据填充到当前的内存区域，这样就起到把前面数据往后挪的作用，也是往右填充
                    memcpy(bitmapData +index * 4, pixel, 4);
                }
            }else{
                //这里是把上一行的往下填充
                preIndex = (i - 1) * width + j;
                memcpy(bitmapData + index * 4, bitmapData + preIndex * 4, 4);
            }
        }
    }
    
    //把数据转回位图，再从位图转回UIImage
    NSUInteger dataLength = width * height * 4;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bitmapData, dataLength, NULL);
    
    CGImageRef mosaicImageRef = CGImageCreate(width, height,
                                              8,
                                              32,
                                              width*4 ,
                                              colorSpace,
                                              kCGBitmapByteOrderDefault,
                                              provider,
                                              NULL, NO,
                                              kCGRenderingIntentDefault);
    CGContextRef outputContext = CGBitmapContextCreate(nil,
                                                       width,
                                                       height,
                                                       8,
                                                       width*4,
                                                       colorSpace,
                                                       kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(outputContext, CGRectMake(0.0f, 0.0f, width, height), mosaicImageRef);
    CGImageRef resultImageRef = CGBitmapContextCreateImage(outputContext);
    UIImage *resultImage = nil;
    if([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)]) {
        float scale = [[UIScreen mainScreen] scale];
        resultImage = [UIImage imageWithCGImage:resultImageRef scale:scale orientation:UIImageOrientationUp];
    } else {
        resultImage = [UIImage imageWithCGImage:resultImageRef];
    }
    CFRelease(resultImageRef);
    CFRelease(mosaicImageRef);
    CFRelease(colorSpace);
    CFRelease(provider);
    CFRelease(context);
    CFRelease(outputContext);
    return resultImage;
}



@end
