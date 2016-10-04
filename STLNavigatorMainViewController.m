//
//  STLNavigatorMainViewController.m
//  STLNavigtorLite
//
//  Created by Vishal Patil on 10/3/12.
//  Copyright (c) 2012 Akruty. All rights reserved.
//

#import <DropboxSDK/DropboxSDK.h>
#import "STLNavigatorMainViewController.h"
#import "STLNavigatorIAPHelper.h"
#import "KxMenu.h"
#import "NEOColorPickerViewController.h"
#include "stl.h"

#define DEFAULT_SCALE 1.0
#define DEFAULT_ORTHO_FACTOR 1.5
#define DEFAULT_ZOOM 2.0
#define MAX_Z_ORTHO_FACTOR 20

static NSString *const kAppKey = @"zyx";
static NSString *const kAppSecret = @"abc";
static NSString *const kBgColor = @"bgcolor";
static NSString *const kFgColor = @"fgcolor";


#define BUFFER_OFFSET(i) ((char *)NULL + (i))

typedef struct {
	GLfloat x;
	GLfloat y;
	GLfloat z;
} vector_t;

// Uniform index.
enum
{
    UNIFORM_MODELVIEWPROJECTION_MATRIX,
    UNIFORM_NORMAL_MATRIX,
    UNIFORM_MATERIAL_COLOR,
    NUM_UNIFORMS
};

// Attribute index.
enum
{
    ATTRIB_VERTEX,
    ATTRIB_NORMAL,
    NUM_ATTRIBUTES
};

@interface STLNavigatorMainViewController ()  <DBRestClientDelegate, UIAlertViewDelegate, NEOColorPickerViewControllerDelegate> {
    NSString *_STLFilepath;
    stl_t *stl_obj;
    BOOL stl_loaded;

    GLfloat *vertices;
    GLuint vertex_cnt;

    GLuint vertexArray;
    GLuint vertexBuffer;

    EAGLContext *gl_context;
    GLKBaseEffect *effect;
    
    float ortho_factor;
    float view_ratio;
    
    int point_cloud;
    
    float zoom;
    
    bool dropbox_enabled;
    bool dropbox_linked;
    DBRestClient *restClient;
    
    bool screen_capture_enabled;
    
    bool rotation_enabled;
    float _rotation;
    
    GLKMatrix4 _projectionMatrix;
    GLKMatrix4 _rotMatrix;
    GLKMatrix4 _modelViewProjectionMatrix;
    GLKMatrix3 _normalMatrix;

    GLKVector3 _anchor_position;
    GLKVector3 _current_position;
    GLKQuaternion _quatStart;
    GLKQuaternion _quat;
    
    GLuint _program;
    GLint uniforms[NUM_UNIFORMS];
    
    BOOL low_memory;
    NSOperationQueue *operationQueue;
    
    NSArray *menuItems;
    UIAlertView *dropboxOptions;
    UIAlertView *buyOptions;
    NSString* buyProductID;
    
    BOOL color_enabled;
    BOOL ipad;
    UIPopoverController *colorPickerPopover;
    UINavigationController *navVC;
    NEOColorPickerViewController *colorPickerController;
    UIColor *bgColor;
    UIColor *fgColor;
}

-(void)initOptions;
-(void)uploadToDropbox;
-(IBAction)showOptions:(id)sender;
-(IBAction)dropboxTapped:(id)sender;
-(IBAction)screenShotTapped:(id)sender;
-(IBAction)pingStatsServer:(id)sender;
-(IBAction)pingDone:(id)sender;
- (void)screenShotSaved:(UIImage*)image didFinishSavingWithError: (NSError *) error contextInfo: (void *) contextInfo;
- (void)setupGL;
- (void)tearDownGL;

- (BOOL)loadShaders;
- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file;
- (BOOL)linkProgram:(GLuint)prog;
- (BOOL)validateProgram:(GLuint)prog;

@end

@implementation STLNavigatorMainViewController
@synthesize glview = _glview;
@synthesize navItem = _navItem;
@synthesize options = _options;

GLKVector4 global_ambient_light = {0, 0, 0, 0};
GLKVector4 object_color = {150.0 / 255.0 , 150.0 / 255.0, 150.0 / 255.0, 1.0};
GLKVector4 light_ambient = {0.3, 0.3, 0.3, 0.0};
GLKVector4 light_diffuse = {0.5, 0.5, 0.5, 1.0};
GLKVector4 light_specular = {0.5, 0.5, 0.5, 1.0};

float mat_shininess = 10.0;
GLKVector4 mat_specular = { 0.5, 0.5, 0.5, 1.0 };

-(void)initDefaultParameters {
    ortho_factor = DEFAULT_ORTHO_FACTOR;
    zoom =  DEFAULT_ZOOM;
    dropbox_enabled = NO;
    screen_capture_enabled = NO;
    color_enabled = NO;
    point_cloud = 0;
    rotation_enabled = YES;
}

-(IBAction)pingStatsServer:(id)sender {
    
    NSString *uuid = [[UIDevice currentDevice] name];
    uuid = [uuid stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding];
    
    NSString *pingURL = [NSString stringWithFormat:@"http://akrutystats.appspot.com/08c87f3c2aca450ae5e4c5e161e7cc7323418f777c2ad2a9973b9187?uuid=%@", uuid];
    
#if (TARGET_IPHONE_SIMULATOR)
    pingURL = [NSString stringWithFormat:@"http://localhost:8080/08c87f3c2aca450ae5e4c5e161e7cc7323418f777c2ad2a9973b9187?uuid=%@", uuid];
#endif
    
    NSURLRequest * urlRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:pingURL]];
    NSURLResponse * response = nil;
    NSError * error = nil;
    [NSURLConnection sendSynchronousRequest:urlRequest
                          returningResponse:&response
                                      error:&error];
    if (error != nil) {
        NSLog(@"ERROR communicating with the stats server: %@", [error localizedDescription]);
    }
    
    [self performSelectorOnMainThread:@selector(pingDone:) withObject:nil waitUntilDone:YES];
}

-(IBAction)pingDone:(id)sender
{
}

-(void)uploadStartDisableControls {
    [self.loadActivityIndicator startAnimating];
    [self.options setUserInteractionEnabled:NO];
    [self.view setUserInteractionEnabled:NO];
    [self.warningLabel setText:NSLocalizedString(@"UPLOADING", nil)];
    [self.warningLabel setHidden:NO];
}

-(void)uploadDoneEnableControls {
    [self.loadActivityIndicator stopAnimating];
    [self.options setUserInteractionEnabled:YES];
    [self.view setUserInteractionEnabled:YES];
    [self.warningLabel setText:NSLocalizedString(@"", nil)];
    [self.warningLabel setHidden:YES];
}

-(void)enableFeatures {
    
    if ([STLNavigatorIAPHelper hasProductBeingPurchased:PRODUCT_ID_DROPBOX_SAVE] == YES) {
        dropbox_enabled = YES;
    }
   
    if ([STLNavigatorIAPHelper hasProductBeingPurchased:PRODUCT_ID_SCREEN_CAPTURE] == YES) {
        screen_capture_enabled = YES;
    }
    
    if ([STLNavigatorIAPHelper hasProductBeingPurchased:PRODUCT_ID_COLOR] == YES) {
        color_enabled = YES;
    }
    
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showOptions:)];
    singleTap.numberOfTapsRequired = 1;
    singleTap.numberOfTouchesRequired = 1;
    [_options addGestureRecognizer:singleTap];
    [_options setUserInteractionEnabled:YES];
}

-(void)loadDefaultSettings {
    [self enableFeatures];
    [self.warningLabel setHidden:YES];
}

-(void)saveDefaultSettings {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs synchronize];
}

-(NSString*)latestSTLfile {
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:documentsDirectory];
    NSDate *modificationDate;
    NSDate *currentLatestDate = nil;
    NSString *file;
    NSString *latestSTL;
    
    while (file = [dirEnum nextObject]) {
        
        if ([[file pathExtension] isEqualToString: @"stl"]) {
            
            file = [documentsDirectory stringByAppendingPathComponent:file];
            modificationDate = [[dirEnum fileAttributes] valueForKey:@"NSFileModificationDate"];
            
            if (currentLatestDate == nil ||
                [modificationDate compare:currentLatestDate] == NSOrderedDescending) {
                currentLatestDate = modificationDate;
                latestSTL = file;
            }
        }
    }
    
    if (latestSTL == nil) {
        // Load a sample STL file
        NSBundle * sampleBundle = [NSBundle bundleWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: @"Samples.bundle"]];
        
        NSString *sample = @"sample.stl";
        latestSTL = [[sampleBundle resourcePath] stringByAppendingPathComponent:sample];
    }
    
    _STLFilepath = latestSTL;
    
    return latestSTL;
}

-(IBAction)loadSTL:(NSString*)path {

    stl_loaded = NO;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        
        NSLog(@"Trying to load file %@", path);
        
        const char *stl_file = [path UTF8String];
        stl_error_t err = STL_ERR_NONE;
        
        if ((stl_obj = stl_alloc()) == NULL) {
            NSLog(@"Problem allocating the STL object");
        }
        
        if (stl_obj && (err = stl_load(stl_obj, (char *)stl_file)) != STL_ERR_NONE) {
            NSLog(@"Problem loading the STL file err = %d", err);
        }
       
        if (err == STL_ERR_NONE) {
            vertex_cnt = stl_vertex_cnt(stl_obj);
        }
        
        if ((err == STL_ERR_NONE) && (err = stl_vertices(stl_obj, &vertices)) != STL_ERR_NONE) {
            NSLog(@"Problem get the vertices for the object = %d", err);
        }
        
        if (err == STL_ERR_NONE) {
            stl_loaded = YES;
        }
        
    } else {
        NSLog(@"%@ file not found", _STLFilepath);
    }
    
    [self performSelectorOnMainThread:@selector(stlLoadComplete:) withObject:path waitUntilDone:YES];
}

-(IBAction)stlLoadComplete:(NSString *)path {
    
    [self.loadActivityIndicator stopAnimating];

    if (stl_loaded == NO) {
        [_glview setNeedsDisplay];
        self.warningLabel.text = NSLocalizedString(@"STL_INVALID_FILE_MESSAGE", nil);
        [self.warningLabel setHidden:NO];
        return;
    }
    
    [self initDraw];
    [self.glview setNeedsDisplay];
}

-(void)initGestureRecognizers {
    
    UITapGestureRecognizer *doubleTapRecognizer = [[UITapGestureRecognizer alloc]
                                                initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTapRecognizer.numberOfTapsRequired = 2;
    [_glview addGestureRecognizer:doubleTapRecognizer];

    
    UIPinchGestureRecognizer *pinchRecognizer = [[UIPinchGestureRecognizer alloc]
                                             initWithTarget:self action:@selector(handlePinch:)];
    [_glview addGestureRecognizer:pinchRecognizer];
    
}

-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.warningLabel.text = @"";
    [self.warningLabel setHidden:YES];
}

-(void)viewWillDisappear:(BOOL)animated {
}

-(void)showAlertMessage:(NSString*)msg {
    [[[UIAlertView alloc]
      initWithTitle:NSLocalizedString(@"APP_TITLE", nil)
      message:msg
      delegate:self
      cancelButtonTitle:NSLocalizedString(@"OK", nil)
      otherButtonTitles: nil] show];    
}

-(void)loadNewSTLfile:(NSString*)path {
     _STLFilepath = path;
    
    [self tearDownSTL];
    [self tearDownGL];
    
    [self.loadActivityIndicator startAnimating];
    NSInvocationOperation *operation = [[NSInvocationOperation alloc]
                                        initWithTarget:self
                                        selector:@selector(loadSTL:)
                                        object:path];
    [operationQueue addOperation:operation];
}

-(void)tearDownSTL {
    
    if (stl_loaded) {
        stl_free(stl_obj);
        stl_loaded = false;
    }
    
    self.warningLabel.text = @"";
    [self.warningLabel setHidden:YES];
}

-(void)initAlertViews
{
    dropboxOptions = [UIAlertView new];
    dropboxOptions.delegate = self;
    
    dropboxOptions.title = NSLocalizedString(@"DROPBOX", nil);
    [dropboxOptions addButtonWithTitle:NSLocalizedString(@"UPLOAD", nil)];
    [dropboxOptions addButtonWithTitle:NSLocalizedString(@"SIGNOUT", nil)];
    
    
    buyOptions = [UIAlertView new];
    buyOptions.delegate = self;
    
    buyOptions.title = NSLocalizedString(@"APP_TITLE", nil);
    [buyOptions addButtonWithTitle:NSLocalizedString(@"BUY", nil)];
    [buyOptions addButtonWithTitle:NSLocalizedString(@"RESTORE", nil)];
    [buyOptions addButtonWithTitle:NSLocalizedString(@"CANCEL", nil)];
}

-(void)initPurchaseNotifications
{
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(productPurchased:) name:kProductPurchasedNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(productPurchaseFailed:) name:kProductPurchaseFailedNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(restoreCompletedTransactionsFinished:) name:kProductRestoreCompletedTransactionsFinished object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(restoreCompletedTransactionsFinishedWithError:)
                                                 name:kProductRestoreCompletedTransactionsFailedWithError
                                               object:nil];
}

-(void)initAsyncOperations
{
    [self.loadActivityIndicator startAnimating];

    operationQueue = [[NSOperationQueue alloc] init];
    NSInvocationOperation *operation = [[NSInvocationOperation alloc]
                                        initWithTarget:self
                                        selector:@selector(pingStatsServer:)
                                        object:nil];
    [operationQueue addOperation:operation];

    NSString *latestSTL = [self latestSTLfile];
    operation = [[NSInvocationOperation alloc]
                 initWithTarget:self
                 selector:@selector(loadSTL:)
                 object:latestSTL];
    
    [operationQueue addOperation:operation];

}

-(void)InitColorChooser
{
    ipad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    colorPickerController = [[NEOColorPickerViewController alloc] init];
    colorPickerController.delegate = self;
    navVC = [[UINavigationController alloc] initWithRootViewController:colorPickerController];
    
    if (ipad) {
        colorPickerPopover = [[UIPopoverController alloc] initWithContentViewController:navVC];
    }
    
    NSData *bgColorData = [[NSUserDefaults standardUserDefaults] objectForKey:kBgColor];
    if (bgColorData) {
        bgColor = [NSKeyedUnarchiver unarchiveObjectWithData:bgColorData];
    } else {
        NSLog(@"Background color not found");
        bgColor = [[UIColor alloc] initWithRed:135.0/255.0 green:206.0/255.0 blue:250.0/255.0 alpha:0.0];
    }
    
    NSData *fgColorData = [[NSUserDefaults standardUserDefaults] objectForKey:kFgColor];
    if (fgColorData) {
        fgColor = [NSKeyedUnarchiver unarchiveObjectWithData:fgColorData];
    } else {
        NSLog(@"Foreground color not found");
        fgColor = [[UIColor alloc] initWithRed:0.8 green:0.8 blue:0.8 alpha:1.0];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _navItem.title = NSLocalizedString(@"APP_TITLE", nil);
    low_memory = NO;
    
    [self loadDefaultSettings];
    
    [self initDefaultParameters];
    [self initGestureRecognizers];
    [self initAsyncOperations];
    [self initAlertViews];
    [self initPurchaseNotifications];
    [self InitColorChooser];
    [self initOptions];
}

-(void)ortho_dimensions_min_x:(GLfloat *)min_x max_x:(GLfloat *)max_x
                        min_y:(GLfloat *)min_y max_y:(GLfloat *)max_y
                        min_z:(GLfloat *)min_z max_z:(GLfloat *)max_z
{
	GLfloat diff_x = stl_max_x(stl_obj) - stl_min_x(stl_obj);
	GLfloat diff_y = stl_max_y(stl_obj) - stl_min_y(stl_obj);
	GLfloat diff_z = stl_max_z(stl_obj) - stl_min_z(stl_obj);
    
    GLfloat max_diff = MAX(MAX(diff_x, diff_y), diff_z);
    
    *min_x = stl_min_x(stl_obj) - ortho_factor*max_diff;
	*max_x = stl_max_x(stl_obj) + ortho_factor*max_diff;
	*min_y = stl_min_y(stl_obj) - ortho_factor*max_diff;
	*max_y = stl_max_y(stl_obj) + ortho_factor*max_diff;
	*min_z = stl_min_z(stl_obj) - MAX_Z_ORTHO_FACTOR * ortho_factor*max_diff;
	*max_z = stl_max_z(stl_obj) + MAX_Z_ORTHO_FACTOR * ortho_factor*max_diff;
}

- (GLKVector3) projectOntoSurface:(GLKVector3) touchPoint
{
    float radius = self.view.bounds.size.width/3;
    GLKVector3 center = GLKVector3Make(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 0);
    GLKVector3 P = GLKVector3Subtract(touchPoint, center);
    
    // Flip the y-axis because pixel coords increase toward the bottom.
    P = GLKVector3Make(P.x, P.y * -1, P.z);
    
    float radius2 = radius * radius;
    float length2 = P.x*P.x + P.y*P.y;
    
    if (length2 <= radius2)
        P.z = sqrt(radius2 - length2);
    else
    {
        /*
         P.x *= radius / sqrt(length2);
         P.y *= radius / sqrt(length2);
         P.z = 0;
         */
        P.z = radius2 / (2.0 * sqrt(length2));
        float length = sqrt(length2 + P.z * P.z);
        P = GLKVector3DivideScalar(P, length);
    }
    
    return GLKVector3Normalize(P);
}

- (void)computeIncremental {
    
    GLKVector3 axis = GLKVector3CrossProduct(_anchor_position, _current_position);
    float dot = GLKVector3DotProduct(_anchor_position, _current_position);
    float angle = acosf(dot);
    
    GLKQuaternion Q_rot = GLKQuaternionMakeWithAngleAndVector3Axis(angle * 2, axis);
    Q_rot = GLKQuaternionNormalize(Q_rot);
    
    // TODO: Do something with Q_rot...
    _quat = GLKQuaternionMultiply(Q_rot, _quatStart);
}


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    
    UITouch * touch = [touches anyObject];
    CGPoint location = [touch locationInView:self.view];
    
    _anchor_position = GLKVector3Make(location.x, location.y, 0);
    _anchor_position = [self projectOntoSurface:_anchor_position];
    
    _current_position = _anchor_position;
    _quatStart = _quat;    
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    
    UITouch * touch = [touches anyObject];
    CGPoint location = [touch locationInView:self.view];
    CGPoint lastLoc = [touch previousLocationInView:self.view];
    CGPoint diff = CGPointMake(lastLoc.x - location.x, lastLoc.y - location.y);
    
    float rotX = -1 * GLKMathDegreesToRadians(diff.y / 2.0);
    float rotY = -1 * GLKMathDegreesToRadians(diff.x / 2.0);
    
    bool isInvertible;
    GLKVector3 xAxis = GLKMatrix4MultiplyVector3(GLKMatrix4Invert(_rotMatrix, &isInvertible), GLKVector3Make(1, 0, 0));
    _rotMatrix = GLKMatrix4Rotate(_rotMatrix, rotX, xAxis.x, xAxis.y, xAxis.z);
    GLKVector3 yAxis = GLKMatrix4MultiplyVector3(GLKMatrix4Invert(_rotMatrix, &isInvertible), GLKVector3Make(0, 1, 0));
    _rotMatrix = GLKMatrix4Rotate(_rotMatrix, rotY, yAxis.x, yAxis.y, yAxis.z);
    
    _current_position = GLKVector3Make(location.x, location.y, 0);
    _current_position = [self projectOntoSurface:_current_position];
    
    [self computeIncremental];
    [_glview setNeedsDisplay];
}

- (IBAction)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
    point_cloud = point_cloud ? 0 : 1;
    [_glview setNeedsDisplay];
}

- (IBAction)handlePinch:(UIPinchGestureRecognizer *)recognizer {
    static float initialZoom;
    
    if (recognizer.state == UIGestureRecognizerStateBegan)
    {
        initialZoom = zoom;
    }
    
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        zoom = [recognizer scale] * initialZoom;
        [_glview setNeedsDisplay];
    }
}

-(void)setViewPort {
    GLfloat min_x, min_y, min_z, max_x, max_y, max_z;
    
    [self ortho_dimensions_min_x:&min_x
                           max_x:&max_x
                           min_y:&min_y
                           max_y:&max_y
                           min_z:&min_z
                           max_z:&max_z];
    
    _projectionMatrix = GLKMatrix4MakeOrtho(min_x,
                                            max_x,
                                            min_y,
                                            max_y,
                                            min_z,
                                            max_z);
    
    _rotMatrix = GLKMatrix4Identity;
    _quat = GLKQuaternionMake(0, 0, 0, 1);
    _quatStart = GLKQuaternionMake(0, 0, 0, 1);
}

-(void)setupBuffers {
    glEnable(GL_DEPTH_TEST);
    
    glGenVertexArraysOES(1, &vertexArray);
    glBindVertexArrayOES(vertexArray);
    
    glGenBuffers(1, &vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER,  6*sizeof(float)*stl_vertex_cnt(stl_obj), vertices,
                 GL_STATIC_DRAW);
    
    glEnableVertexAttribArray(GLKVertexAttribPosition);
    glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE, 24, BUFFER_OFFSET(0));
    glEnableVertexAttribArray(GLKVertexAttribNormal);
    glVertexAttribPointer(GLKVertexAttribNormal, 3, GL_FLOAT, GL_TRUE, 24, BUFFER_OFFSET(12));
    
    glBindVertexArrayOES(0);
}

-(void)setupGL {
    CGRect bounds = _glview.frame;
    float width = bounds.size.width;
    float height = bounds.size.height;
    view_ratio = MAX(width, height) / MIN(width, height);

    [self loadShaders];
    [self setViewPort];
    [self setupBuffers];
}

- (void)tearDownGL
{
    [EAGLContext setCurrentContext:gl_context];
    
    glDeleteBuffers(1, &vertexBuffer);
    glDeleteVertexArraysOES(1, &vertexArray);
    
    effect = nil;    
}

-(void)initDraw {
    
    gl_context = nil;
    gl_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    if (!gl_context) {
        NSLog(@"Failed to create ES context");
        return;
    }
    
    [EAGLContext setCurrentContext:gl_context];
    
    _glview.userInteractionEnabled = YES;
    _glview.context = gl_context;
    _glview.delegate = self;
    
    [self setupGL];
}

-(void)applyTransformations {
    
    GLKMatrix4 baseModelViewMatrix = GLKMatrix4MakeTranslation(0.0f, 0.0f, 0.0f);
    GLKMatrix4 modelViewMatrix = GLKMatrix4MakeTranslation(((stl_max_x(stl_obj) + stl_min_x(stl_obj))/2),
                              ((stl_max_y(stl_obj) + stl_min_y(stl_obj))/2),
                              ((stl_max_z(stl_obj) + stl_min_z(stl_obj))/2));

    modelViewMatrix = GLKMatrix4Multiply(baseModelViewMatrix, modelViewMatrix);
    modelViewMatrix = GLKMatrix4Scale(modelViewMatrix, zoom, zoom/view_ratio, zoom);
    
    GLKMatrix4 rotation = GLKMatrix4MakeWithQuaternion(_quat);
    modelViewMatrix = GLKMatrix4Multiply(modelViewMatrix, rotation);
    
    modelViewMatrix = GLKMatrix4Translate(modelViewMatrix,
                                          -((stl_max_x(stl_obj) + stl_min_x(stl_obj))/2),
                                          -((stl_max_y(stl_obj) + stl_min_y(stl_obj))/2),
                                          -((stl_max_z(stl_obj) + stl_min_z(stl_obj))/2));
    
    _normalMatrix = GLKMatrix3InvertAndTranspose(GLKMatrix4GetMatrix3(modelViewMatrix), NULL);
    _modelViewProjectionMatrix = GLKMatrix4Multiply(_projectionMatrix, modelViewMatrix);
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    [bgColor getRed:&red green:&green blue:&blue alpha:&alpha];
    glClearColor(red, green, blue, alpha);
    
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    if(stl_loaded == NO || low_memory == YES) {
        return;
    }
    
    glBindVertexArrayOES(vertexArray);
    [self applyTransformations];
    
    glUseProgram(_program);
    
    glUniformMatrix4fv(uniforms[UNIFORM_MODELVIEWPROJECTION_MATRIX], 1, 0, _modelViewProjectionMatrix.m);
    glUniformMatrix3fv(uniforms[UNIFORM_NORMAL_MATRIX], 1, 0, _normalMatrix.m);
    
    [fgColor getRed:&red green:&green blue:&blue alpha:&alpha];
    glUniform4f(uniforms[UNIFORM_MATERIAL_COLOR], red, green, blue, alpha);
    
    glDrawArrays(point_cloud ? GL_LINES: GL_TRIANGLES, 0, stl_vertex_cnt(stl_obj));
}

#pragma mark -  OpenGL ES 2 shader compilation

- (BOOL)loadShaders
{
    GLuint vertShader, fragShader;
    NSString *vertShaderPathname, *fragShaderPathname;
    
    // Create shader program.
    _program = glCreateProgram();
    
    // Create and compile vertex shader.
    vertShaderPathname = [[NSBundle mainBundle] pathForResource:@"SimpleVertex" ofType:@"glsl"];
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER file:vertShaderPathname]) {
        NSLog(@"Failed to compile vertex shader");
        return NO;
    }
    
    // Create and compile fragment shader.
    fragShaderPathname = [[NSBundle mainBundle] pathForResource:@"SimpleFragment" ofType:@"glsl"];
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER file:fragShaderPathname]) {
        NSLog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // Attach vertex shader to program.
    glAttachShader(_program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(_program, fragShader);
    
    // Bind attribute locations.
    // This needs to be done prior to linking.
    glBindAttribLocation(_program, GLKVertexAttribPosition, "position");
    glBindAttribLocation(_program, GLKVertexAttribNormal, "normal");
    
    // Link program.
    if (![self linkProgram:_program]) {
        NSLog(@"Failed to link program: %d", _program);
        
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (_program) {
            glDeleteProgram(_program);
            _program = 0;
        }
        
        return NO;
    }
    
    // Get uniform locations.
    uniforms[UNIFORM_MODELVIEWPROJECTION_MATRIX] = glGetUniformLocation(_program, "modelViewProjectionMatrix");
    uniforms[UNIFORM_NORMAL_MATRIX] = glGetUniformLocation(_program, "normalMatrix");
    uniforms[UNIFORM_MATERIAL_COLOR] = glGetUniformLocation(_program, "materialColor");
    
    // Release vertex and fragment shaders.
    if (vertShader) {
        glDetachShader(_program, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader) {
        glDetachShader(_program, fragShader);
        glDeleteShader(fragShader);
    }
    
    return YES;
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file
{
    GLint status;
    const GLchar *source;
    
    source = (GLchar *)[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] UTF8String];
    if (!source) {
        NSLog(@"Failed to load vertex shader");
        return NO;
    }
    
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    
    return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;
    
    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

#pragma mark - Options

-(void)initOptions
{
    menuItems =
    @[
      [KxMenuItem menuItem:NSLocalizedString(@"DROPBOX", nil)
                     image:[UIImage imageNamed:@"dropbox_icon.png"]
                    target:self
                    action:@selector(dropboxTapped:)],
      
      [KxMenuItem menuItem:NSLocalizedString(@"SCREEN_CAPTURE", nil)
                     image:[UIImage imageNamed:@"screenshot.png"]
                    target:self
                    action:@selector(screenShotTapped:)],
      
      [KxMenuItem menuItem:NSLocalizedString(@"SELECT_COLOR", nil)
                     image:[UIImage imageNamed:@"color_wheel_icon.png"]
                    target:self
                    action:@selector(selectColorTapped:)]

      ];    
}

-(IBAction)showOptions:(UITapGestureRecognizer *)sender
{
    [KxMenu showMenuInView:self.view
                  fromRect:_options.frame
                 menuItems:menuItems];
}

#pragma mark - SelectColor
-(IBAction)selectColorTapped:(id)sender
{
    if (color_enabled == NO) {
        buyOptions.message = NSLocalizedString(@"FEATURE_COLOR_NOT_PURCHASED", nil);
        buyProductID = PRODUCT_ID_COLOR;
        [buyOptions show];
        return;
    }
    
    if (ipad) {
        [colorPickerPopover presentPopoverFromRect:[self.view frame] inView:self.view permittedArrowDirections:0 animated:YES];
    } else {
        [self presentViewController:navVC animated:YES completion:nil];
    }
}

-(void)dissmissColorPicker {
    if (ipad) {
        [colorPickerPopover dismissPopoverAnimated:YES];
    } else {
        [colorPickerController dismissViewControllerAnimated:YES completion:nil];
    }
}

-(UIColor*)calculateBgColor
{
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    [fgColor getRed:&red green:&green blue:&blue alpha:&alpha];

    int d = 0;
    
    // Counting the perceptive luminance - human eye favors green color...
    double a = 1 - ( 0.299 * red + 0.587 * green + 0.114 * blue);
    
    if (a < 0.5)
        d = 40; // bright colors - black font
    else
        d = 220; // dark colors - white font
    
    return [[UIColor alloc] initWithRed:d/255.0 green:d/255.0 blue:d/255.0 alpha:0.0];
}

- (void) colorPickerViewController:(NEOColorPickerBaseViewController *)colorPickerController didSelectColor:(UIColor *)color {
    fgColor = color;
    bgColor = [self calculateBgColor];
    [_glview setNeedsDisplay];
    
    NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:fgColor];
    [[NSUserDefaults standardUserDefaults] setObject:colorData forKey:kFgColor];
    
    colorData = [NSKeyedArchiver archivedDataWithRootObject:bgColor];
    [[NSUserDefaults standardUserDefaults] setObject:colorData forKey:kBgColor];
    
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [self dissmissColorPicker];
}

- (void) colorPickerViewControllerDidCancel:(NEOColorPickerBaseViewController *)colorPickerController {
    [self dissmissColorPicker];
}

#pragma mark - Screenshot

-(IBAction)screenShotTapped:(id)sender
{
    if (screen_capture_enabled == NO) {
        buyOptions.message = NSLocalizedString(@"FEATURE_SCREENCAPTURE_NOT_PURCHASED", nil);
        buyProductID = PRODUCT_ID_SCREEN_CAPTURE;
        [buyOptions show];
        return;
    }
    
    UIImage *screenshot = [_glview snapshot];
    UIImageWriteToSavedPhotosAlbum(screenshot, self, @selector(screenShotSaved:didFinishSavingWithError:contextInfo:), nil);
}

- (void)screenShotSaved:(UIImage*)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    if (error) {
        [self showAlertMessage:NSLocalizedString(@"SCREENSHOT_SAVE_FAILURE", nil)];
    } else {
        [self showAlertMessage:NSLocalizedString(@"SCREENSHOT_SAVE_SUCCESS", nil)];
    }
}

#pragma mark - Dropbox

-(BOOL)isAuthorized {
    return [[DBSession sharedSession] isLinked];
}

-(BOOL)signOut {
    BOOL status = YES;
    [[DBSession sharedSession] unlinkAll];
    return status;
}

-(void)initDropboxSession {
    DBSession* dbSession = [[DBSession alloc] initWithAppKey:kAppKey
                                                   appSecret:kAppSecret
                                                        root:kDBRootAppFolder];
    [DBSession setSharedSession:dbSession];
    restClient = [[DBRestClient alloc] initWithSession:[DBSession sharedSession]];
    
    restClient.delegate = self;
}

- (void)dropboxTapped:(id)sender {
    
    if (dropbox_enabled == NO) {
        buyOptions.message = NSLocalizedString(@"FEATURE_DROPBOX_NOT_PURCHASED", nil);
        buyProductID = PRODUCT_ID_DROPBOX_SAVE;
        [buyOptions show];
        return;
    }
    
    [self initDropboxSession];
    dropbox_linked = [[DBSession sharedSession] isLinked];
    if (dropbox_linked == NO) {
        NSLog(@"Dropbox not linked");
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        [[DBSession sharedSession] linkFromController:window.rootViewController];
        return;
    }
    
    [dropboxOptions show];
}

-(void)uploadToDropbox {
    [self uploadStartDisableControls];
    NSString *filename = [_STLFilepath lastPathComponent];
    NSString *destDir = @"/";
    [restClient uploadFile:filename toPath:destDir
                    withParentRev:nil fromPath:_STLFilepath];
}

- (void)restClient:(DBRestClient*)client uploadedFile:(NSString*)destPath
              from:(NSString*)srcPath metadata:(DBMetadata*)metadata {    
    [self.loadActivityIndicator stopAnimating];
    [self showAlertMessage:NSLocalizedString(@"UPLOAD_SUCCESSFULL", nil)];
    [self uploadDoneEnableControls];
}

- (void)restClient:(DBRestClient*)client uploadFileFailedWithError:(NSError*)error {
    [self.loadActivityIndicator stopAnimating];
    [self showAlertMessage:NSLocalizedString(@"UPLOAD_FAILED", nil)];
    [self uploadDoneEnableControls];
}

- (void)didReceiveMemoryWarning
{
     [super didReceiveMemoryWarning];
     self.warningLabel.text = NSLocalizedString(@"LOW_MEMORY", nil);
     [self.warningLabel setHidden:NO];
}


#pragma mark - Feature Purchase

-(void)showAlertMessage:(NSString *)title message:(NSString *)msg {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:msg
                                                   delegate:nil
                                          cancelButtonTitle:nil
                                          otherButtonTitles:@"OK", nil];
    [alert show];
}

- (void)buyButtonTapped:(NSString *)productId {
    NSLog(@"Trying to buy %@", productId);
    
    NSArray *products = [STLNavigatorIAPHelper productsLeftToBePurchased];
    if ([products count] == 0) {
        [self showAlertMessage:NSLocalizedString(@"ITUNES_FAILURE", nil)];
        return;
    }
    
    [_loadActivityIndicator startAnimating];
    [[STLNavigatorIAPHelper sharedHelper] buyProductIdentifier:productId];
}

- (void)restoreTapped:(int)productId {
    [_loadActivityIndicator startAnimating];
    [[STLNavigatorIAPHelper sharedHelper] restoreCompletedTransactions];
}

- (void)productPurchased:(NSNotification *)notification {
    [_loadActivityIndicator stopAnimating];
    [self enableFeatures];
}

- (void)restoreCompletedTransactionsFinished:(NSNotification *)notification {
    [self showAlertMessage:NSLocalizedString(@"APP_TITLE", nil)
                   message:NSLocalizedString(@"RESTORATION_COMPLETE", nil)];
    
    [_loadActivityIndicator stopAnimating];
}

- (void)restoreCompletedTransactionsFinishedWithError:(NSNotification *)notification {
    [self showAlertMessage:NSLocalizedString(@"APP_TITLE", nil)
                   message:NSLocalizedString(@"RESTORATION_FAILED", nil)];
    
    [_loadActivityIndicator stopAnimating];
}

- (void)productPurchaseFailed:(NSNotification *)notification {
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    SKPaymentTransaction * transaction = (SKPaymentTransaction *) notification.object;
    if (transaction.error.code != SKErrorPaymentCancelled) {
        [self showAlertMessage:NSLocalizedString(@"ERROR", nil) message:transaction.error.localizedDescription];
        [_loadActivityIndicator stopAnimating];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView == dropboxOptions) {
        
        switch (buttonIndex) {
            case 0:
                [self uploadToDropbox];
                break;
            case 1:
                [self signOut];
                break;
            default:
                break;
        }
    }
    
    if (alertView == buyOptions) {
        switch (buttonIndex) {
            case 0:
                [self buyButtonTapped:buyProductID];
                break;
            case 1:
                [self restoreTapped:buyProductID];
                break;
            default:
                break;
        }
    }
}

@end
