module ThermovisorData
    using Images,ImageShow,ImageIO
    using Plots,CSV
    using Colors, ColorVectorSpace
    using Dates,Statistics,LinearAlgebra
    using ImageSegmentation,IndirectArrays
    using Optim
    using LaTeXStrings
    using Distributions # to evaluate the Students coefficient
    using PerceptualColourMaps # to draw heatmaps
    using StaticArrays
    using Interpolations
    import ImageDraw

    export RescaledImage,FilteredImage,
        full_image_flag,reduced_image_flag,draw!,
        draw,fit_centred_obj!,
        radius,diameter,area,side,center,
        CircleObj,SquareObj,RectangleObj,
        CentredObj,obj_from_vect,copyobj,
        fill_im!,fill_im_external!,
        filtered_mean,filtered_std,
        filter_image,filter_image!,
        marker_image,
        read_temperature_file,
        find_temperature_files,
        along_line_distribution,
        within_mask_line_distribution

    """
    ThermovisorData

is a package designed to process thermal images stored as matrices
Each  element of thermal image represents a temperature value. The package enables users to 
load images from files, calculate temperature distributions, and compute statistical analyses
for temperatures along specified lines. It also calculates averaged angular and radial temperature
distributions (along with standard deviations) within Regions of Interest (ROIs [`CentredObj`](@ref)) 
such as  circles, squares, and rectangles. These ROI objects can be fitted to 
distinct areas (relative to their surroundings), such as the most heated regions within
the scene.
    
    """    
    ThermovisorData

    const default_images_folder = Ref(joinpath(abspath(joinpath(@__DIR__, "..")),"thermal images"))
    const FlagMatrix = Union{Matrix{Bool},BitMatrix}
    const FlagVector = Union{Vector{Bool},BitVector}
    const int_floor_abs = Int ∘ floor ∘ abs
    const int_floor = Int ∘ floor
    const int_floor_fld = Int ∘ floor ∘ fld
    const DefColorScheme = Ref("HEAT")
    const DEFAULT_FITTING_OPTIONS = Ref(Optim.Options(x_abstol=1,iterations=30))
    """
	    RescaledImage - structure stores the image data mapped to region  [0,1]
Fields:

initial  - initial image before rescaling

sz - size of the image

min - minimum value

max  - maximum value

im - image with all values from 0 to 1 
"""
    mutable struct RescaledImage{T} 
        initial::Matrix{T}
        sz::Tuple{Int,Int}
        min::T
        max::T
        im::Matrix{T}
        RescaledImage(image::Matrix{T}) where T<:Number =begin
            sz = size(image)
            new{T}(image,sz,rescale!(copy(image))...)
        end
    end
    Base.size(image::RescaledImage) = image.sz
    Base.copy(image::RescaledImage) = RescaledImage(copy(image.initial))
    function rescale!(image::AbstractMatrix)
        min,max = extrema(image)
        @. image = (image - min)/(max-min)
        return (min,max,image)
    end
    """
        Type to store image with filtered temperature region 

:full - filtered rescaled image of the same size as the input with all pixels which are not the part of the pattern with label value 

:region_indices - cartesian indices of the pattern in the input image

:reduced - image of reduced size where all not-inpatter pixels removed  
    (the 	scaling of this image is the same as of the input `imag.initial` 
    see [`RescaledImage`](@ref) type )

:reduced_flag - bitmatrix version of (reduced)
"""
    mutable struct FilteredImage{T}
        full::RescaledImage{T}
        region_indices::Vector{CartesianIndex{2}}
        reduced::SubArray{T,2,Matrix{T},Tuple{UnitRange{Int},UnitRange{Int}},false}
        reduced_flag::SubArray{Bool,2,BitMatrix,Tuple{UnitRange{Int},UnitRange{Int}},false}
    end
    
    """
    full_image_flag(filtered_im::FilteredImage)

Returns the BitMatrix flag of filtered pattern in the whole image.

Can be used as index matrix in the full image e.g.:
 `filtered_image.full.initial[full_image_flag(filtered_image)]` will return 
 all elements which belong to the pattern

"""
function full_image_flag(filtered_im::FilteredImage) 
        flag = BitMatrix(undef,filtered_im.full.sz...)
        fill!(flag,false)
        @. flag[filtered_im.region_indices]=true
        return flag
    end   
    reduced_image_flag(fim::FilteredImage) =  copy(fim.reduced_flag)  
    reduced_image(fim::FilteredImage) = copy(fim.reduced)
    """
    image_discr(im1,im2)

Calculates the scalar distance between two matrices by checking the equality of their elements
"""
function image_discr(im1,im2)
        # calculates distance between two bit-images of the same size 
        N = prod(size(im1))
        return sum(1 - i[1]==i[2] for i in zip(im1,im2))/(2*N)
    end
    
    """
    `CentredObj` is a sort of region of interest (ROI) marker object. 

`CentredObj` has centre coordinates, object's center can be 
anywhere with respect to the image indices. ROI also has one or more size parameters (in pixels)
coordinates of centre are equal to CartesianIndices, first element is the row index, 
the second element is the column index!! (y and x coordinate)
This is opposite to the ImageDraw, where first Point coordinate corresponds to the column index and 
the second one to the row index. `CentredObj` can also be used as for indexing image[c] - returns all
elements of image within c, `image[c]=x` sets all elements of image to the values of x, x firstindex 
should be 1. `CentredObj` can also be used to set all image points within the ROI to a single value.
e.g. `image[c] = 30` 

To impement `CentredObj` abstraction one needs to implement:

[`is_within`](@ref) - function to check if inds are within the `CentredObj`

[`line_within_mask`](@ref) - function to check if all line points are within the `CentredObj`

[`fill_x0!`](@ref) - function to fill the optimization starting vector during `CentredObj` 
fitting the image

[`convert_to_drawable`](@ref) fucntion to convert the [`CentredObj`](@ref) to a drawable obj for `ImageDraw`

[`parnumber`](@ref) function which returns the number of parameters     

"""
abstract type CentredObj end 
    
"""
    parnumber(::Type{T}) where T<:CentredObj

Returns total number of parameters needed to create new object
"""
function parnumber(::Type{T}) where T<:CentredObj    error(DomainError(T,"Undefined parnumber method")) end

"""
    (::Type{T})() where T<:CentredObj

Empty object constructor
"""
function (::Type{T})() where T<:CentredObj
    N = parnumber(T)
    obj_from_vect(T,Vector{Int}(undef,N))
end
    """
        copyobj(c::T) where T<:CentreObj

Copies the [`CentredObj`](@ref) creating new instance
"""
    function copyobj(c::T) where T<:CentredObj 
        return obj_from_vect(T,[c.center...,c.dimensions...])
    end    
    """
    Base.length(c::CentredObj)

Total number of values needed to create [`CentredObj`](@ref) of specified type
"""
function Base.length(::T) where T<:CentredObj
        return parnumber(T)
    end 
    """
    is_within(c::CentredObj,_)

Function to check if indices are within [`CentredObj`](@ref)
"""
function is_within(c::CentredObj,_)  DomainError(typeof(c),"no implementation") end
    """
    is_within(c::CentredObj,i::CartesianIndex)

`CartesianIndex` support
"""
function is_within(c::CentredObj,i::CartesianIndex) 
        return is_within(c,SVector(Tuple.(i)))
    end 
    revcentre(c::CentredObj) = reverse(c.center)
    """
    is_within_iterator(img::AbstractMatrix,c::CentredObj)

Iterator over all `CartesianIndices` within the `img` which are within the CentredObj `c`
"""
function is_within_iterator(img::AbstractMatrix,c::CentredObj)
        return Iterators.filter(i->is_within(c,i),keys(img))
    end   
    """
    Base.getindex(img::AbstractMatrix,c::CentredObj)

`CentredObj` can be used for matrix indexing, `image[centred_object]` - returns the vector 
of temperatures of all points of image lying within the `centred_object` of `CentredObj`
"""
function Base.getindex(img::AbstractMatrix,c::CentredObj)
        return map(i->Base.getindex(img,i),is_within_iterator(img,c))
    end
    """
    Base.setindex!(img::Matrix,x::Array,c::CentredObj)

img[c]=x assignes all x elements to the elements of `img` with indices lying within the `CentredObj` c
"""
function Base.setindex!(img::Matrix,x::Array,c::CentredObj)
        @assert firstindex(x)==1 # check if it is not obset array
        for (ix,iimg) in enumerate(is_within_iterator(img,c))
            img[iimg] = x[ix]
        end
        return nothing
    end
"""
    Base.setindex!(img::Matrix{T},x::Number,c::CentredObj) where T

Setting all elements within the `CentredObj` to a single value
"""
function Base.setindex!(img::Matrix{T},x::Number,c::CentredObj) where T
        x_T = T(x) 
        for i in is_within_iterator(img,c)
            img[i] = x_T
        end
        return nothing
    end

    """
    shift!(c::CentredObj,x::AbstractVector)

Relative shift of centred object center
"""
function shift!(c::CentredObj,x::AbstractVector)
        @. c.center +=x 
        return nothing
    end
    """
    line_within_mask(c::CentredObj,ang::Float64,line_length::Int)

Function returns endpoint of the line lying fully within the mask  - tuple of four point which can be 
directly splatted to the along_line_distribution

ang - angle in degrees 

line_length - the length of line   
"""
function line_within_mask(c::CentredObj,::Float64,::Int)  DomainError(typeof(c),"no implementation") end
    """
    area(c::CentredObj)

Ealuates the surface area in pixels
"""
function area(c::CentredObj) DomainError(typeof(c),"no implementation") end
    """
        fill_x0!(x0,im_bin::AbstractMatrix,c::CentredObj)

Fills the optimization starting vector by seraching the centre of the image `im_bin`
"""
function fill_x0!(x0,im_bin::FlagMatrix,c::CentredObj) DomainError(typeof(c),"no implementation") end
    """
    convert_to_drawable(::CentredObj)

Converts CentredObj to a drawable structure appropriate to the `ImageDraw`
draw function, polygon,ellipse see [`ImageDraw.draw`] function 
"""
function convert_to_drawable(::CentredObj) end
    """
    fill_im!(img,c::CentredObj)

Fills bitmatrix `img` in a way that all pixels which are 
within the `CentredObj` are true and false otherwise.  
"""
    function fill_im!(img,c::CentredObj)
        for i in keys(img)
            inds = [k for k in Tuple.(i)]
            img[i] = is_within(c,inds)
        end
        return img
    end
"""
    fill_vect!(x::AbstractVector, c::CentredObj)

Converts `CentredObj` to vector
"""
function fill_vect!(x::AbstractVector, c::CentredObj)
    x[1] = c.center[1];x[2]=c.center[2];
    x[3:end] .= c.dimensions
    return x
end
    """
    draw!(image::Matrix{Float64},c::CentredObj;fill=false,thickness::Int=55,color::RGB{Float64}=RGB{Float64}(0,1,0), kwargs...)

Draws CentreObj inside the image.

image - image

c - object 

fill - if true the interior of the object will be filled 

thickness - the thickness of the object's frame

color - frame and filling color 
"""
function draw!(image::Matrix{Float64},c::CentredObj;fill=false,thickness::Int=-1,
                                        color::RGB{Float64}=RGB{Float64}(0,1,0), 
                                        color_scheme::String="",show_cross=true,kwargs...) 

        rgbim = to_rgb(image,color_scheme=color_scheme)
        #im_pic = ImageDraw.draw!(rgbim,LineTwoPoints(points_inds...), RGB{Float64}(1,0,0))             
        return   draw!(rgbim,c;
            fill=fill,thickness=thickness, 
            color=color, show_cross=show_cross,kwargs...)   
    end
    draw(image::Matrix{Float64};color_scheme::String=DefColorScheme[]) = to_rgb(image,color_scheme=color_scheme)
    draw(image::RescaledImage;color_scheme::String=DefColorScheme[]) = draw(image.initial,color_scheme=color_scheme)
    draw(image::FilteredImage;color_scheme::String=DefColorScheme[],draw_reduced::Bool=false) = draw_reduced ? draw(reduced_image(image),color_scheme=color_scheme) : draw(image.full,color_scheme=color_scheme) 
    
    function draw!(rgbim::Matrix{RGB{Float64}},
        c::CentredObj;fill=false,
        thickness::Int=55,
        color::RGB{Float64}=RGB{Float64}(0,1,0), show_cross=true,kwargs...) 

        ImageDraw.draw!(rgbim,convert_to_drawable(c,fill=fill,thickness=thickness), color; kwargs...)
        
        show_cross ? ImageDraw.draw!(rgbim, ImageDraw.Cross(ImageDraw.Point(revcentre(c)...), 50), color) : nothing

        return rgbim
    end

    """
    to_rgb(image::Matrix{Float64};color_scheme::String="")

Converts matrix to rgb martix by applyting the color scheme 
using `applycolourmap` function from `PerceptualColourMaps`  
"""
function to_rgb(image::Matrix{Float64};color_scheme::String="")
        if Base.length(color_scheme)==0 
            color_scheme = DefColorScheme[]
        end
        rgbimg_3D = applycolourmap(image,PerceptualColourMaps.cmap(color_scheme))

        return collect(colorview(RGB, permuteddimsview(rgbimg_3D,(3,1,2))) )
    end

    """
    draw(c::CentredObj;kwargs...)

Returns `CentredObj` image of minimal possible size
"""
function draw(c::CentredObj;kwargs...) 
        (x_left,y_left,x_right,y_right) = abs.(diagonal_points(c))
        image = fill(0.0,[y_right+y_left,x_right + x_left]...)
        image[1,1]=0.001            
        return draw!(image,c;kwargs...)
    end
    function draw_line_within_mask(image::Matrix{Float64},c::CentredObj,ang,length;thickness::Int=55,
                        color::RGB{Float64}=RGB{Float64}(0,1,0), color_scheme::String="",kwargs...) 
        rgbim = to_rgb(image,color_scheme=color_scheme)
        return draw_line_within_mask!(rgbim,c,ang,length;thickness=thickness,
                    color=color, kwargs...)
    end
    function draw_line_within_mask!(rgbim::Matrix{T},
            c::CentredObj,ang,length;
            thickness::Int=55,
            color::T=T(0,1,0), kwargs...) where T<:RGB{Float64}

            line_coords = line_within_mask(c,ang,length)
            #we should interchange the order of coordinates according to the ImageDraw demands
            ImageDraw.draw!(rgbim,ImageDraw.LineSegment(line_coords[2],line_coords[1],line_coords[4],line_coords[3]), color)
            
            return rgbim
    end

    #
    """
    fill_im_external!(img::FlagMatrix,c::CentredObj)
	
Fills image matrix `img` in a way that all pixels which are 
not within the CentreObj set to true.  See also `is_within`
"""
    function fill_im_external!(img::FlagMatrix,c::CentredObj)
        for i in keys(img)
            inds = [k for k in Tuple.(i)]
            img[i] = !is_within(c,inds)
        end
        return img
    end    
    """
    fit_centred_obj!(c::CentredObj,im_bin::FlagMatrix;
                                starting_point::Union{Nothing,Vector{Float64}}=nothing,
                                optimizer::Optim.ZerothOrderOptimizer = Optim.NelderMead(), 
                                options::Optim.Options=Optim.Options())

Fits [`CentredObj`](@ref) to binary image pattern (region of units) by adjusting centre coordinates and dimentions
using zeroth-order optimizers from `Optim.jl` package.

Input variables:

c - `CentredObj` (modified)   

im_bin - binarized image (BitMatrix or Matrix{Bool})

(optional)

starting_point - staring vector (uses [`fill_x0!`](@ref) function to fill starting point by default)

optimizer - zeroth-order optimizer from `Optim.jl` package

options  - optimization options from `Optim.jl` package

"""
function fit_centred_obj!(c::CentredObj,im_bin::FlagMatrix;
                                starting_point::Union{Nothing,Vector{Float64}}=nothing,
                                optimizer::Optim.ZerothOrderOptimizer = Optim.NelderMead(), 
                                options::Optim.Options=DEFAULT_FITTING_OPTIONS[]) 

        optim_fun = image_fill_discr(im_bin,c) 
        x0 = Vector{Float64}(undef,length(c))
	    if isnothing(starting_point)
		    fill_x0!(x0,im_bin,c)
        else
            x0 = copyto!(x0,starting_point)
	    end
	    optim_out = optimize(optim_fun,x0,optimizer,options)
	    return (c,Optim.minimum(optim_out),optim_out)
    end
    """
    fit_centred_obj!(c::CentredObj,image::FilteredImage;
                                        starting_point::Union{Nothing,Vector{Float64}}=nothing,fit_reduced::Bool=true,
                                        optimizer::Optim.ZerothOrderOptimizer = NelderMead(),options::Optim.Options=DEFAULT_FITTING_OPTIONS[])

Fits [`CentredObj`](@ref) (modified) to filtered image (not modified)
`fit_reduced` flag (default=true) indicates what version of the image should be fitted if true - 
reduced otherwise - full image. For other input arguments see [`fit_centred_obj!(c::CentredObj,im_bin::FlagMatrix)`](@ref)
"""
function fit_centred_obj!(c::CentredObj,image::FilteredImage;
                                        starting_point::Union{Nothing,Vector{Float64}}=nothing,fit_reduced::Bool=true,
                                        optimizer::Optim.ZerothOrderOptimizer = NelderMead(),options::Optim.Options=DEFAULT_FITTING_OPTIONS[]) 
        return fit_reduced ? fit_centred_obj!(c,reduced_image_flag(image),starting_point=starting_point,optimizer = optimizer,options=options) : fit_centred_obj!(c,full_image_flag(image),starting_point=starting_point,optimizer = optimizer,options=options)
    end
    """
    fit_all_patterns(img::RescaledImage,::Type{T}=CircleObj;
                                            level_threshold::Float64=0.8,
                                            distance_threshold::Float64=1e-3,
                                            max_centred_objs::Int=100,
                                            optimizer::Optim.ZerothOrderOptimizer = NelderMead(),
                                            options::Optim.Options=DEFAULT_FITTING_OPTIONS[]) where T<:CentredObj

Function fits all patterns of the image `img` to the vector of [`CentredObj`](@ref) ROI objects. 
The type of ROI should be provided as a second arguments (by default it is a [`CircleObj`](@ref))

img - input image of [`RescaledImage`](@ref) type

For other input arguments see [`marker_image`](@ref) and [`fit_centred_obj!(c::CentredObj,im_bin::FlagMatrix)`](@ref)
"""
function fit_all_patterns(img::RescaledImage,::Type{T}=CircleObj;
                                            level_threshold::Float64=0.8,
                                            distance_threshold::Float64=1e-3,
                                            max_centred_objs::Int=200,
                                            optimizer::Optim.ZerothOrderOptimizer = NelderMead(),
                                            options::Optim.Options=DEFAULT_FITTING_OPTIONS[]) where T<:CentredObj
                                            
            markers = marker_image(img,level_threshold=level_threshold,distance_threshold=distance_threshold)     
            markers_number = count_separate_patterns(markers)       
            markers_number=minimum((markers_number,max_centred_objs))    
            if markers_number<=0 
                 return Vector{T}([])  
            else
                centered_objs_to_fit = [T() for _ in 1:markers_number]
            end
            Threads.@sync for (i,c) in enumerate(centered_objs_to_fit)
                Threads.@spawn ThermovisorData.fit_centred_obj!(c,markers.==i,optimizer = optimizer,options = options)
            end
            return centered_objs_to_fit
    end  
"""
    count_separate_patterns(markers::Matrix{Int})

This function takes matrix of markers see [`marker_image`](@ref) and calculates the number of separate patterns
"""
function   count_separate_patterns(markers::Matrix{Int})
    return maximum(markers)
end
    """
    image_fill_discr(image::AbstractMatrix,c::CentredObj)

Function returns the function to evaluate the discrepancy  between 
`CentredObj` and the matrix, this function is used during the fitting procedure 
"""    
function image_fill_discr(image::AbstractMatrix,c::CentredObj)
         im_copy = copy(image)   
         return x-> image_discr(image, fill_im!(im_copy,fill_from_vect!(c,x)))
    end
    """
    center(c::CentredObj)

Returns objects central point 
"""
function center(c::CentredObj)  c.center.data end
    """
    dimensions(c::CentredObj)

Return dimentional parameters (vector)
"""
function dimensions(c::CentredObj)  c.dimentions.data end

Base.:*(c::CentredObj,a::Number) = begin 
    c_copy = copyobj(c)
    @. c_copy.dimensions = int_floor_abs(a*c_copy.dimensions)
    return c_copy
end
Base.:*(a::Number,c::CentredObj) = c*a
Base.:/(c::CentredObj,a::Number) = begin 
    c_copy = copyobj(c)
    @. c_copy.dimensions = int_floor_abs(c_copy.dimensions/a)
    return c_copy
end
    """
    obj_from_vect(::Type{CentredObj},v::AbstractVector)

Creates object from parameters vector, first two arguments are center
point other are dimentions [center[1],center[2],dimentions[1],...]
"""
    function obj_from_vect(::Type{T},v::AbstractVector) where T<:CentredObj
            c = T() # empty constructor calling
            fill_from_vect!(c, v)
            return c
    end
    
    """
    fill_from_vect!(c::CentredObj, v::AbstractVector)

Fills CentreObj parameters from the vector [center_index_1,center_index_2,dimention_1,dimention_2,...]
"""
    function fill_from_vect!(c::CentredObj, v::AbstractVector)
        @assert length(c)==Base.length(v)
        l_d = Base.length(c.dimensions)
        map!(int_floor,c.center,v[1:2])
        map!(int_floor_abs,c.dimensions,v[3:2+l_d])
        return c
    end
    #-------------------------CIRCLE-OBJ---------------------------
"""
Circle object with defined diemeter
"""
    mutable struct CircleObj <:CentredObj
        center::MVector{2,Int} # central point location (indices)
        dimensions::MVector{1,Int} # side length{1,Int} # diameter
        CircleObj(center,diameter::Number) = begin
            new(MVector{2}(map(int_floor_abs, center)),MVector{1}(int_floor_abs(diameter)))
        end
        CircleObj() = new(MVector{2}(1,1),MVector{1}(1))
    end
    parnumber(::Type{CircleObj}) = 3
    diameter(c::CircleObj) = c.dimensions[]
    radius(c::CircleObj) = c.dimensions[]/2
    side(c::CircleObj) = diameter(c)
    area(c::CircleObj) = π*radius(c)^2
    is_within(c::CircleObj,inds::AbstractVector) = sqrt(sum(abs2  , c.center .- inds)) < radius(c)

    """
    fill_x0!(x0,im_bin::FlagMatrix,::CircleObj)

Fills starting vector for the optimization of `CentredObj`
"""
    function fill_x0!(x0,im_bin::FlagMatrix,::CircleObj)

            min_ind = findfirst(im_bin)
            max_ind = findlast(im_bin)

		    starting_diameter= sqrt(sum(abs2, Tuple.(max_ind - min_ind)))

            x0 .= [collect(x/2 for x in Tuple.(max_ind + min_ind))..., starting_diameter]
    end    
    """
    line_within_mask(c::CircleObj,ang,line_length)

Returns two endpoints of the line lying totally inside the `CentredObj`
"""
function line_within_mask(c::CircleObj,ang,line_length) 
        ang %= 360
        line_length = line_length>diameter(c) ? radius(c) : line_length/2 
        
        lsin = int_floor(line_length*sind(ang))
        lcos = int_floor(line_length*cosd(ang))

        return        [c.center[1] -  lcos,
                       c.center[2] -  lsin,
                       c.center[1] +  lcos,
                       c.center[2] +  lsin]
    end
    function convert_to_drawable(c::CircleObj;fill=false,thickness::Int=-1)
        if (thickness==-1)&& !fill
            thickness = int_floor(0.17*diameter(c))
        end
        return ImageDraw.CirclePointRadius(c.center[2],c.center[1],radius(c),thickness=thickness,fill=fill)
    end
    #-----------------------SQUARE-OBJ---------------------------
    """
Square with defined center and side
"""
    mutable struct SquareObj <:CentredObj
        center::MVector{2,Int}
        dimensions::MVector{1,Int} # side length
        
        SquareObj(center,side) = begin
            new(MVector{2}(map(int_floor_abs, center)),MVector(int_floor_abs(side)))
        end
        SquareObj() = new(MVector{2}(1,1),MVector{1}(1))
    end
    parnumber(::Type{SquareObj}) = 3
    area(c::SquareObj)=^(c.dimensions[],2)
    side(c::SquareObj) = c.dimensions[]

    is_within(c::SquareObj,inds::AbstractVector) = begin
        a = side(c)/2
        c.center[1]-a <=inds[1]<=c.center[1]+a   && c.center[2]-a <=inds[2]<=c.center[2]+a
    end
    
    function fill_x0!(x0,im_bin::FlagMatrix,::SquareObj)
        
        min_ind = findfirst(im_bin)
        max_ind = findlast(im_bin)
        starting_side = sqrt(sum(abs2, Tuple.(max_ind - min_ind)))
       x0 .= [collect(x/2 for x in Tuple.(max_ind + min_ind))..., starting_side]

    end  

    function line_within_mask(c::SquareObj,ang,line_length) 
        a = side(c)
        ang %=360
        if (45<=ang<=135) || (225<=ang<=315)
            a_l = abs(a/sind(ang))
            if line_length>a_l
                line_length = a_l
            end   
            lsin_f = line_length*sind(ang)/2
            lcos_f = line_length*cosd(ang)/2
        else
            a_l = abs(a/cosd(ang))
            if line_length>a_l
                line_length = a_l
            end   
            lsin_f = line_length*sind(ang)/2
            lcos_f = line_length*cosd(ang)/2         
        end

        
        lsin = int_floor(lsin_f)
        lcos = int_floor(lcos_f)

        return      [  c.center[1]- lcos,
                       c.center[2]- lsin,
                       c.center[1]+ lcos,
                       c.center[2]+ lsin ]
    end
    """
    diagonal_points(c::Union{SquareObj,CircleObj})

Returns diagonal points in row-column coordinates
"""
diagonal_points(c::Union{SquareObj,CircleObj}) = begin
        a = side(c)
        a=int_floor_fld(a,2)
        return (c.center[1]-a , c.center[2]-a, c.center[1]+a , c.center[2]+a)
    end
    """
    rearranged_diagonal(c::Union{SquareObj,CircleObj})

Returns diagonal points in x-y coordinates
"""
rearranged_diagonal(c::Union{SquareObj,CircleObj}) = begin
        a = side(c)
        a=int_floor_fld(a,2)
        return (c.center[2]-a,c.center[1]-a ,c.center[2]+a, c.center[1]+a )
    end
    #--------------------------RECTANGLE-OBJ-----------------------

    """
    Rectangular object with defined two sides
"""
    mutable struct RectangleObj <:CentredObj

        center::MVector{2,Int}
        dimensions::MVector{2,Int} # two sized
       
        RectangleObj(center,sides) = begin
            d = MVector{2,Int}(undef)
            @. d = int_floor_abs(sides)
            new( MVector{2}(map(int_floor_abs, center)),d)
        end
        RectangleObj() = new(MVector{2}(1,1),MVector{2}(1,1))
    end
    parnumber(::Type{RectangleObj}) = 4
    area(c::RectangleObj)=*(side(c)...)
    side(c::RectangleObj) = (c.dimensions[1],c.dimensions[2])
    is_within(c::RectangleObj,inds::AbstractVector) = begin
        (a,b) = side(c)
        a/=2
        b/=2
        c.center[1]-a<=inds[1]<=c.center[1]+a   && c.center[2]-b<=inds[2]<=c.center[2]+b
    end
    diagonal_points(c::RectangleObj) = begin
        (a,b) = side(c)
        a=int_floor_fld(a,2) # corresponds to vertical size(row index)
        b=int_floor_fld(b,2) # horizontal side (column index)
        return (c.center[1]-a , c.center[2]-b, c.center[1]+a , c.center[2]+b)
    end
    rearranged_diagonal(c::RectangleObj) = begin
        (a,b) = side(c)
        a=int_floor_fld(a,2)
        b=int_floor_fld(b,2)
        return (c.center[2]-b,c.center[1]-a , c.center[2]+b, c.center[1]+a )
    end
    function convert_to_drawable(c::Union{RectangleObj,SquareObj};kwargs...)
        return  ImageDraw.Polygon(ImageDraw.RectanglePoints(rearranged_diagonal(c)...))
    end

    function fill_x0!(x0,im_bin::FlagMatrix,::RectangleObj)
        #(min_ind,max_ind) = extrema(findall(im_bin))
        min_ind = findfirst(im_bin)
        max_ind = findlast(im_bin)

        starting_a = sqrt(sum(abs2, Tuple.(max_ind - min_ind)))
        starting_b = starting_a
        x0 .= [collect(x/2 for x in Tuple.(max_ind + min_ind))...,starting_a,starting_b]
    end 
    function diag_ang(c::RectangleObj)
        a,b = side(c)
        return atand(a/b)
    end
    function line_within_mask(c::RectangleObj,ang,line_length) 
        b,a = side(c) # here we interchange the sides
        ang %=360
        rect_ang = diag_ang(c)
        if ((90-rect_ang)<=ang<=(180-rect_ang)) || ((270-rect_ang)<=ang<=(360-rect_ang))
            a_l = abs(a/sind(ang))
            if line_length>a_l
                line_length = a_l
            end   
            lsin_f = line_length*sind(ang)/2
            lcos_f = line_length*cosd(ang)/2
        else
            a_l = abs(b/cosd(ang))
            if line_length>a_l
                line_length = a_l
            end   
            lsin_f = line_length*sind(ang)/2
            lcos_f = line_length*cosd(ang)/2         
        end

        
        lsin = int_floor(lsin_f)
        lcos = int_floor(lcos_f)

        return      [  c.center[1]- lcos,
                       c.center[2]- lsin,
                       c.center[1]+ lcos,
                       c.center[2]+ lsin ]
        end


    """
        `filter_image(imag::RescaledImage,markers;label=0)`

Funtion zeroes all pixels of the image, except those belonging to the specified pattern.
`image` - rescaled image (see [`RescaledImage`](@ref) type)
`markers` - the matrix of the same size as the input image, each element of this matrix has unique value-label associated with some pattern.  Function `label_components` returns the markers matrix.
(optional) - the value of the label to be selected as a pattern marker

Function returns [`FilteredImage`](@ref) object
"""
    function filter_image(imag::RescaledImage,markers::Matrix{Int};label=0)
        # function extracts from markerd image
        # markers - the matrix with all labeled elements
        # imag - initial rescaled image 
        return filter_image!(copy(imag.initial),external_flag_from_marker(markers,label=label))
    end
    """
    external_flag_from_marker(markers::Matrix{Int};label=0,external=true)

Converts patterns markers matrix (image where each pattern marked with its own integer) 
to flag matrix of region external (if external is true) of internal otherwise , 
if label equals zero  looks for  pattern with maximal number of pixels

"""
function external_flag_from_marker(markers::Matrix{T};label::T=0,external::Bool=true) where T<:Int
        max_label = maximum(markers)
        if label>0 && label<=max_label
            max_label=label
        else
            max_area = 0
            for l in 1:max_label
                cur_area= count(==(l),markers)
                if cur_area>max_area
                    max_area = cur_area
                    max_label = l
                end
            end
        end

        return external ? markers .!=max_label : markers .==max_label 
    end
    """
    filter_image(imag::AbstractMatrix,c::CentredObj;external=false)

Filters image according to centered object creating new image
if external  is true than as a filtering flag the inverse of centered object image is taken
"""
   filter_image(imag::AbstractMatrix,c::CentredObj;external=false) = filter_image!(copy(imag),cent_to_flag(c,size(imag),external= !external))
   filter_image(imag,flag::FlagMatrix) =  filter_image!(copy(imag),flag)
   filter_image(imag::RescaledImage;label = 0) = filter_image(imag,marker_image(imag),label=label)
   """
    filter_image(imag::RescaledImage,c::CentredObj;external=false)

Filters image according 
"""
    filter_image(imag::RescaledImage,c::CentredObj;external=false) = filter_image(imag.initial,c;external=external)
    """
    filter_image!(imag::AbstractMatrix,flag::BitMatrix)

Returns `FilteredImage` taking all elements of imag which are not external_region_flag
"""
function filter_image!(imag::AbstractMatrix,external_region_flag::FlagMatrix)
        external_region = @view imag[external_region_flag]
        @. external_region=0.0
        @. external_region_flag = !external_region_flag
        region_area_indices = findall(external_region_flag)
        min_ind,max_ind = extrema(region_area_indices)
        square_view = @view imag[min_ind[1]:max_ind[1],min_ind[2]:max_ind[2]]
        square_view_flag =@view  external_region_flag[min_ind[1]:max_ind[1],min_ind[2]:max_ind[2]]
        return FilteredImage(RescaledImage(imag),
                region_area_indices,
                square_view, 
                square_view_flag)
    end
    filter_image!(imag::AbstractMatrix,c::CentredObj;external=false) = filter_image!(imag,cent_to_flag(c,size(imag),external=!external))

    """
    cent_to_flag(c::CentredObj,sz::Tuple{Int,Int};external=false)

Converts CentredObj to bitmatrix  of size sz
"""
    function cent_to_flag(c::CentredObj,sz::Tuple{Int,Int};external=false)
        external_part_flag = BitMatrix(undef,sz...)
        return external ? fill_im_external!(external_part_flag,c) : fill_im!(external_part_flag,c)
    end

    """
    cent_to_flag(::Type{T},c::CentredObj,sz::Tuple{Int,Int};external=false) where T<:FlagMatrix

Converts centred obj to BitMatrix of the Matrix of bool see `FlagMatrix
"""
function cent_to_flag(::Type{T},c::CentredObj,sz::Tuple{Int,Int};external=false) where T<:FlagMatrix
        external_part_flag = T(undef,sz...)
        return external ? fill_im_external!(external_part_flag,c) : fill_im!(external_part_flag,c)
    end

    """
    filter_image!(imag::RescaledImage{Float64},external_region_flag::FlagMatrix)::FilteredImage

In-place filtering of `RescaledImage`
"""
    function filter_image!(imag::RescaledImage{Float64},
        external_region_flag::FlagMatrix)::FilteredImage
        
        external_region = view(imag.initial,external_region_flag)
        @. external_region=0.0
        @. external_region_flag = !external_region_flag
        region_area_indices = findall(external_region_flag)
        min_ind,max_ind = extrema(region_area_indices)
        @. imag.im = imag.initial
        rescale!(imag.im)
        square_view = @view  imag.initial[min_ind[1]:max_ind[1],min_ind[2]:max_ind[2]]
        square_view_flag =@view external_region_flag[min_ind[1]:max_ind[1],min_ind[2]:max_ind[2]]
        return FilteredImage(imag,
                region_area_indices,
                square_view, 
                square_view_flag)       
    end
    filter_image!(imag::RescaledImage,c::CentredObj;external::Bool=false) = filter_image!(imag,cent_to_flag(c,imag.sz,external= !external))
    filtered_mean(fltrd::FilteredImage) = Statistics.mean(fltrd.reduced[fltrd.reduced_flag])
    filtered_std(fltrd::FilteredImage) = Statistics.std(fltrd.reduced[fltrd.reduced_flag])
    """
    marker_image(rescaled::RescaledImage,level_threshold::Float64,distance_threshold::Float64=1e-3)

Markers image patterns, input umage is `RescaledImage` image type, 
level_threshold  - should be between 0.0 and 1.0
distance_threshold  - criterium of image binarization after distance transform

returns `markers`  - matrix of Int's with the same size as the input matrix, each element 
of `markers` is the label index of individual patterns of the initial image
"""
    function marker_image(rescaled::RescaledImage;
                    level_threshold::Float64=0.8,distance_threshold::Float64=1e-3)
        dist =  distance_transform(feature_transform(rescaled.im .> level_threshold))
        markers = label_components(dist .< distance_threshold)
        return markers
    end


    """
    read_temperature_file(f_name::AbstractString)

Reads temeprature file `f_name` is a full file name
"""
function read_temperature_file(f_name::AbstractString)
		if isfile(f_name)
			file_full_path = f_name
		else
			file_full_path = joinpath(default_images_folder[],f_name)
            isfile(file_full_path) ? nothing : return nothing
		end
		m_file = CSV.File(file_full_path,header=false,types=Float64)
		pic = RescaledImage(CSV.Tables.matrix(m_file));
		creation_time = mtime(file_full_path)
		return (pic,creation_time)
    end
    
    """
        `find_temperature_files(folder::AbstractString)`

Searchs the folder for thermal images files using `is_temperature_file`
Returns dictionary `Dict{String,Pair{Float64,String}}` with keys parts of files matched 
using `is_temperature_file`, values - are temperature pairs of `Float64` => `full-file-name`
When file name contains "_BB_" it supposed to be the blackbody themperature distribution       
"""
function find_temperature_files(folder::AbstractString=default_images_folder[])

        files = Dict{String,Pair{Float64,String}}()
        for file in readdir(folder)
            if !contains(file,".csv")
                continue
            end
            reg_match = is_temperature_file(file)
            if !isnothing(reg_match)
                t = parse(Float64,reg_match[1])
                t_key = contains(file,"_BB_") ? "B"*reg_match[1] : reg_match[1]
                counter = 1
                t_key_check = t_key
                while haskey(files,t_key_check)
                    t_key_check = t_key*"-"*string(counter)
                    counter+=1
                end
                t_key = t_key_check
                files[t_key] =t=>joinpath(folder,file)
            end
        end
        return files
    end
    """
        `is_temperature_file(file_name::AbstractString)`

Checks if the file with `file_name` has an appropriate name for thermovisor temperature distribution file
"""
    is_temperature_file(file_name::AbstractString)=match(r"_T([1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]).csv",file_name)
    
    """
    mean_within_mask(img::AbstractMatrix,c::CentredObj)

Evaluates the average temperature of all points within the `CentredObj` marker
"""
function mean_within_mask(img::AbstractMatrix,c::CentredObj)
        flt = Iterators.filter(i->is_within(c,i),keys(img))
        return Statistics.mean(i->img[i],flt)
    end

    """
    std_within_mask(img::AbstractMatrix, c::CentredObj)

Evaluates standard deviation of temperature for all points within the `CentredObj` marker
"""
function std_within_mask(img::AbstractMatrix, c::CentredObj)
        flt = Iterators.filter(i->is_within(c,i),keys(img))
        mpper = Iterators.map(i->img[i],flt)
        return Statistics.std(mpper)
    end
    """
    along_line_distribution(img::AbstractMatrix{T},x0,y0,x1,y1) where T

Function evaluates matrix values distribution along the line specified by two coordinates, 
img - input image 
returns the tuple of two vectors: coordinates and values 
see `ImageDraw.bresenham` for details of finding the points of the line 
    
returns 
points - vector of coordinates along the line
distrib - distribution
"""
function along_line_distribution(img::AbstractMatrix{T},x0,y0,x1,y1) where T
            dx = abs(x1 - x0)
            dy = abs(y1 - y0)

            sx = x0 < x1 ? 1 : -1
            sy = y0 < y1 ? 1 : -1;

            err = (dx > dy ? dx : -dy) / 2
            points = Vector{CartesianIndex}()
            distrib = Vector{T}()
            while true
                Base.push!(points,CartesianIndex(x0,y0))
                Base.push!(distrib,img[x0,y0])
                (x0 != x1 || y0 != y1) || break
                e2 = err
                if e2 > -dx
                    err -= dy
                    x0 += sx
                end
                if e2 < dy
                    err += dx
                    y0 += sy
                end
            end
        return (points,distrib)
    end
    

    """
    add_distrib_point!(points,distrib,point,value)

Internal fucntion to add the point to distribution
"""
add_distrib_point!(points,distrib,point,value) = begin
        Base.push!(points,point)
        Base.push!(distrib,value)       
    end
    """
    along_line_distribution_xiaolin_wu(img::AbstractMatrix{T}, y0, x0, y1, x1) where T

Evaluates the value matrix content along the line with endpoint coordinates x0,y0,y1,x1,
returns indices of all points. As far as Wu's algorithm returns two adjacent points
the value is evaluated as an average of two point obtained with Wu's algorithm

see  `xiaolin_wu` function from `ImageDraw` 
"""
function along_line_distribution_xiaolin_wu(img::AbstractMatrix{T}, y0, x0, y1, x1) where T
            dx = x1 - x0
            dy = y1 - y0

            swapped=false
            if abs(dx) < abs(dy)
                x0, y0 = swap(x0, y0)
                x1, y1 = swap(x1, y1)
                dx, dy = swap(dx, dy)
                swapped=true
            end
            if x1 < x0
                x0, x1 = swap(x0, x1)
                y0, y1 = swap(y0, y1)
            end
            gradient = dy / dx

            points = Vector{CartesianIndex}()
            distrib = Vector{T}()

            xend = round(Int, x0)
            yend = y0 + gradient * (xend - x0)
            xgap = rfpart(x0 + 0.5)
            xpxl0 = xend
            ypxl0 = trunc(Int, yend)
            index = swapped ? CartesianIndex(xpxl0, ypxl0) : CartesianIndex(ypxl0, xpxl0)

            #drawifinbounds!(img, index, T(rfpart(yend) * xgap))
            prev_val = img[index]
            index = swapped ? CartesianIndex(xpxl0, ypxl0 + 1) : CartesianIndex(ypxl0 + 1, xpxl0)
            #drawifinbounds!(img, index, T(fpart(yend) * xgap))
            add_distrib_point!(points,distrib,index,0.5*(img[index]+prev_val))

            intery = yend + gradient
            xend = round(Int, x1)
            yend = y1 + gradient * (xend - x1)
            xgap = fpart(x1 + 0.5)
            xpxl1 = xend
            ypxl1 = trunc(Int, yend)

            index = swapped ? CartesianIndex(xpxl1, ypxl1) : CartesianIndex(ypxl1, xpxl1)
            prev_val = img[index]

            index = swapped ? CartesianIndex(xpxl1, ypxl1 + 1) : CartesianIndex(ypxl1 + 1, xpxl1)
            add_distrib_point!(points,distrib,index,0.5*(img[index]+prev_val))


            for i in (xpxl0 + 1):(xpxl1 - 1)
                index = swapped ? CartesianIndex(i, trunc(Int, intery)) : CartesianIndex(trunc(Int, intery), i)
                prev_val = img[index]

                index = swapped ? CartesianIndex(i, trunc(Int, intery) + 1) : CartesianIndex(trunc(Int, intery) + 1, i)
                add_distrib_point!(points,distrib,index, 0.5*(img[index]+prev_val))

                intery += gradient
            end
            inds = fill(0,Base.length(points))
            sortperm!(inds,points)
            points .=points[inds]
            distrib .=distrib[inds]
            return (points,distrib)
        end
        function swap(x, y)
            y, x
        end
        fpart(pixel::T) where {T} = pixel - T(trunc(pixel))
        rfpart(pixel::T) where {T} = oneunit(T) - fpart(pixel)
    """
    within_mask_line_points_distribution(imag::AbstractMatrix,c::CentredObj,direction_angle=0.0,line_length=10.0;use_wu::Bool=false)

Function evaluates the distribution of values in `imag` matrix along the line with length `line_length` in pixels
oriented with the angle `direction_angle` in degrees  with respect to the posistive direction of oX (column index increase), 
this line lies within the mask (`CentreObj`) and goes through its center.

Function returns:

points  - vector of `CartesianIndex` of image's points lying on the line

distrib - distribution of values

line_points - endpoints of line the Tupple of (left_x,left_Y,right_x,right_y)

"""
    function within_mask_line_points_distribution(imag::AbstractMatrix,c::CentredObj,
                            direction_angle=0.0,line_length=10.0;
                            use_wu::Bool=false)

        line_points = line_within_mask(c,direction_angle,line_length) 
        points_within_line!(imag,line_points)
        if use_wu
            (points,distrib) = along_line_distribution_xiaolin_wu(imag,line_points...)
        else
            (points,distrib) = along_line_distribution(imag,line_points...)
        end
        return (points,distrib,line_points)
    end
    """
    along_mask_line_distribution(imag::AbstractMatrix,c::CentredObj,direction_angle=0.0,line_length=10.0;
                                                                                                length_per_pixel=1.0,
                                                                                                use_wu::Bool=false)


The same as `within_mask_line_points_distribution` but returns the line length along the coordinates within the 
image.

`line_length` - the length of line in the same units as `length_per_pixel`.
The calibration `using mm_per_pixel``, returns calibrated length along the line 

"""
    function along_mask_line_distribution(imag::AbstractMatrix,c::CentredObj,
                                        direction_angle=0.0,  line_length=10.0;
                                        length_per_pixel=1.0, use_wu::Bool=false)
        
        line_length = line_length/length_per_pixel         # converting line_length to pixels                                                                            
        (points,distrib,line_points) = within_mask_line_points_distribution(imag,c,direction_angle,line_length,
                                                                                                        use_wu=use_wu)
        along_line_length = line_points_to_along_length(points,line_points)*length_per_pixel
        return (along_line_length,distrib,line_points)
    end
    """
    radial_distribution(imag::AbstractMatrix,c::CentredObj,angles_range::AbstractRange,line_length;mm_per_pixel=1.0)

Calls `along_mask_line_distribution` on lines oriented with some angles range and puts the resulting 
distribution into one matrix j'th column of this matrix corresponds to the distribution along the line oriented with ang[j] angle
"""
function radial_distribution(imag::AbstractMatrix,c::CentredObj,
                                angles_range::AbstractRange;line_length=0.0,
                                                length_per_pixel=1.0,
                                                use_wu::Bool=false)
        # first calling to obtain the length
        line_length = line_length <=0.0 ? minimum(c.dimensions) : line_length 
        (first_columnn_along_line,_,) = along_mask_line_distribution(imag,c,0.0, line_length;length_per_pixel=length_per_pixel,use_wu=use_wu)
        # 
        points_number = Base.length(first_columnn_along_line)
        angles_number = Base.length(angles_range)
        radial_distrib_matrix = fill(NaN,points_number,angles_number)#Matrix{Float64}(undef,points_number,angles_number)

        extrapolation_bc = Interpolations.Line()
        #extrapolation_bc = Interpolations.Flat()
        Threads.@sync for (i,α) in enumerate(angles_range) # circle over line rotation angle 
            Threads.@spawn begin 
                (along_line_length,distrib,) = along_mask_line_distribution(imag,c,α, line_length;length_per_pixel=length_per_pixel,use_wu=use_wu)
                w_distr = @view radial_distrib_matrix[:,i]
                along_line_distrib = LinearInterpolation(along_line_length,distrib,extrapolation_bc = extrapolation_bc)(first_columnn_along_line) 
                copyto!(w_distr,along_line_distrib)
            end
        end
        return (first_columnn_along_line,radial_distrib_matrix)
    end

    """
    radial_distribution_statistics(along_length_coordinate,distrib;length_per_pixel=1.0,is_use_student=true)

This function evaluates mean radial diatribution, it's standard deviation and student's coefficient 
Input arguments `along_length`, `distrib` -  distribution matrix. All rows of distrib which contains NaNs will be 
droped.

Optional:

max_length - maximal value of along_length_coordinate to be includet in to the statistics evaluation

is_use_student - flag if use students's coefficient

"""
function radial_distribution_statistics(along_length_coordinate::AbstractVector,distrib::AbstractVecOrMat;
    max_length=-1.0,min_length=-1.0,is_use_student::Bool=true)
        @assert(length(along_length_coordinate)==size(distrib,1),"Vector of coordinate should have the same length as the number of distrib rows")
        not_nan_flag = _inbounds_flag(along_length_coordinate,distrib,max_length,min_length)
        L = @view along_length_coordinate[not_nan_flag]
        D = @view distrib[not_nan_flag,:]
        return _eval_stats(L,D,is_use_student)
    end
    """
    _inbounds_flag(L,D,max_length,min_length)

Unsafe version of check! number of  rows in `D` should be the same as the number of 
elements in `L`
Returns Bool flag of all row not containing NaN's and lying within the min_length to max_length range
"""
function _inbounds_flag(L,D,max_length,min_length)
        not_nan_flag = Vector{Bool}(undef,size(D,1)) 
        if max_length>0 && max_length < maximum(L)
            if  min_length>0 && min_length>minimum(L)
                for (i,r) in enumerate(eachrow(D))
                    @inbounds not_nan_flag[i] = !any(isnan,r) && L[i]<=max_length && L[i]>=min_length
                end
            else
                for (i,r) in enumerate(eachrow(D))
                    @inbounds not_nan_flag[i] = !any(isnan,r) && L[i]<=max_length
                end
            end
        else
            for (i,r) in enumerate(eachrow(D))
                @inbounds not_nan_flag[i] = !any(isnan,r)
            end
        end
        return not_nan_flag
    end
    function _eval_stats(L,D,is_use_student)
       mean_D = Vector{Float64}(undef,length(L))
       #@show size(mean_D)
       #@show size(D)
        Statistics.mean!(mean_D,D)
        std_D = vec(Statistics.stdm(D,mean_D,dims=2))
        samples_number = size(D,2)
        t_value = student_coefficient(samples_number,0.95)
        l_b = similar(mean_D)
        u_b = similar(mean_D)
        if is_use_student
            @. l_b = mean_D - t_value*std_D
            @. u_b = mean_D + t_value*std_D
        else
            @. l_b = mean_D - std_D
            @. u_p = mean_D + std_D
        end
        return (copy(L),mean_D,std_D,l_b,u_b,t_value)
    end

    """
    angular_distribution_statistics(angles,along_length_coordinate,distrib;
                                max_length=-1.0,is_use_student::Bool=true)

Function evaluates average temperature distribution vs angle of orientation
"""
function angular_distribution_statistics(angles,along_length_coordinate,distrib;
                                max_length=-1.0,min_length=-1.0,is_use_student::Bool=true)
        
        not_nan_flag = _inbounds_flag(along_length_coordinate,distrib,max_length,min_length)
        #L = @view along_length_coordinate[not_nan_flag]
        D =transpose( @view distrib[not_nan_flag,:])
        return _eval_stats(angles,D,is_use_student)
    end
    """
    points_within_line!(imag::AbstractMatrix,line_points::AbstractVector)

Forces all line points to lie within the possible region according toe the image size
"""
function points_within_line!(imag::AbstractMatrix,line_points::AbstractVector)
        sz = size(imag)
        for (ind,l) in enumerate(line_points)
            if l<=0
                line_points[ind] = 1
            else
                s = isodd(ind) ? sz[1] : sz[2]
                if  l>s
                    line_points[ind] = s
                end
            end
        end
        return line_points
    end
    """
    plot_along_line_distribution(along_line_length,along_line_distribution;
                                        length_scaler::Float64=1.0,
                                        is_centered::Bool=true,kwargs...)

Plots temperature distribution along the line `along_line_length` - coordinates,
`along_line_distribution` - values of temperature, `length_scaler` - length scaler 
(can be used to convert pixels to the actual length)
`is_centered` - the line length is converted to the coordinates with zero value in 
the centre of the `CentredObj`

"""
function plot_along_line_distribution(along_line_length,along_line_distribution;
                                        length_scaler::Float64=1.0,
                                        is_centered::Bool=true,kwargs...)
        #centr = center(c)
	    if !is_centered
            p_line=plot(length_scaler*along_line_length,along_line_distribution,gridlinewidth=2,framestyle = :box,kwargs...)
        else
            p_line=plot(length_scaler*(along_line_length .- along_line_length[end]/2),along_line_distribution,
            gridlinewidth=2,
            framestyle = :box,kwargs...)
        end
	    xlabel!(p_line,L"Distance \ along \ the \ line \ ,\ mm")
	    ylabel!(p_line,L"Temperature \ \degree C")
	    title!(p_line,"Temperature distribution along the line")
        return p_line
    end
    """
    plot_radial_distribution_statistics(L,mean_D::T,std_D::T,
        lower_bound::Union{T,Nothing}=nothing,upper_bound::Union{T,Nothing}=nothing;
                length_scaler::Float64=1.0,
                is_centered::Bool=true,label=nothing,
                minorgrid=true,gridlinewidth=2,title="Average temperature radial distribution",
                framestyle = :box,
                dpi=600,xlabel = "Distance  across the sample ,mm", ylabel="Temperature  °C",
                kwargs...)      where T<:AbstractVector

    Plots radial ditribution averaged value, confidence bounds and confidence bounds
    multiplied by the Student's coefficient
"""
function plot_radial_distribution_statistics(L,mean_D::T,std_D::T,
        lower_bound::Union{T,Nothing}=nothing,upper_bound::Union{T,Nothing}=nothing;
                length_scaler::Float64=1.0,
                is_centered::Bool=true,label=nothing,
                minorgrid=true,gridlinewidth=2,title="Average temperature radial distribution",framestyle = :box,
                dpi=600,xlabel = L"Distance  \ across \ the \ sample ,mm", ylabel=L"Temperature \ \degree C",
                kwargs...)      where T<:AbstractVector
        points_number = Base.length(L)
        if is_centered || length_scaler != 1.0
            L2plot = copy(L)
            if is_centered
                l_center = L[int_floor(points_number/2)] 
                @. L2plot= L-l_center
            end
            L2plot .*=length_scaler
        else
            L2plot=L
        end    
	    p=plot(L2plot,
		    mean_D,label=label,
		    minorgrid=minorgrid,
		    gridlinewidth=gridlinewidth,
		    title=title,
		    ribbon = (std_D,std_D), framestyle = framestyle,dpi=dpi,kwargs...)
	    xlabel!(p,xlabel)
	    ylabel!(p,ylabel)
        !isnothing(lower_bound) ? plot!(p,L2plot,lower_bound,linecolor=:red,label=nothing) : nothing
        !isnothing(upper_bound) ?  plot!(p,L2plot,upper_bound,linecolor=:red,label=nothing) : nothing
        return p

    end
    """
    plot_angular_distribution_statistics(angles,mean_D::T,std_D::T,
                lower_bound::Union{T,Nothing}=nothing,upper_bound::Union{T,Nothing}=nothing;
                length_scaler::Float64=1.0,
                label=nothing,
                minorgrid=true,
                gridlinewidth=2,
                title="Average temperature angular distribution",framestyle = :box,
                dpi=600,xlabel = L"Angle  ,°", ylabel=L"Temperature °C",
                kwargs...)      where T<:AbstractVector

 The same as `plot_radial_distribution_statistics` but plots averaged angular distribution
"""
function plot_angular_distribution_statistics(angles,mean_D::T,std_D::T,
                lower_bound::Union{T,Nothing}=nothing,upper_bound::Union{T,Nothing}=nothing;
                length_scaler::Float64=1.0,
                label=nothing,
                minorgrid=true,
                gridlinewidth=2,
                title="Average temperature angular distribution",framestyle = :box,
                dpi=600,xlabel = L"Angle  \ ,\degree", ylabel=L"Temperature \ \degree C",
                kwargs...)      where T<:AbstractVector

                return plot_radial_distribution_statistics(angles,mean_D,std_D,
                        lower_bound,upper_bound;
                        length_scaler=length_scaler,
                        is_centered=false,
                        label=label,
                        minorgrid=minorgrid,gridlinewidth=gridlinewidth,
                        title=title,framestyle = framestyle,
                        dpi=dpi,xlabel = xlabel, ylabel=ylabel,
                        kwargs...) 

    end
    """
    line_points_to_along_length(along_line_points::Vector{T},line_points) where T

    Converts Cartesian indices of `along_line_points` to the length along line
"""
function line_points_to_along_length(along_line_points::Vector{T},line_points) where T
        line_start = T(Tuple(line_points[1:2]))
        length_along_line = Vector{Float64}(undef,Base.length(along_line_points))
        for (i,x) in enumerate(along_line_points)
			length_along_line[i]= sqrt(sum(abs2, Tuple(x-line_start)))
	    end
        return length_along_line
    end

"""
    student_coefficient(degrees_of_freedom::Int, probability; digits::Int = 3, side::Int = 2)

    Evaluates Student's distribution coefficient
"""
function student_coefficient(degrees_of_freedom::Int, probability; digits::Int = 3, side::Int = 2)
	# dof - degrees of freedome
	# probability
	if side == 2
        probability = (1+probability)/2
    end
	return round(Distributions.quantile(Distributions.TDist(degrees_of_freedom), probability),digits=digits)
end
#
end
